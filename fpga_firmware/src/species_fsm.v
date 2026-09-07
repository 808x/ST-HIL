module species_fsm (
    input wire clk,
    input wire rst_n,
    input wire button_n,        // manual override button (active-high on this board)
    input wire [7:0] rx_data,
    input wire rx_valid,
    input wire tx_busy,
    output reg [7:0] tx_data,
    output reg tx_valid,
    output reg led_inject,      // active-low: brightness ~ valve opening
    output reg led_stop         // active-low: lights when stopped
);

    localparam SYNC_BYTE   = 8'hAA;
    localparam DIAG_SYNC   = 8'hBB;
    localparam CONFIG_SYNC = 8'hBC;

    // Clock is 27 MHz.
    localparam CLK_HZ      = 27_000_000;
    localparam WATCHDOG_MS = 200;
    localparam WATCHDOG_LIMIT = (CLK_HZ / 1000) * WATCHDOG_MS;
    localparam PWM_PERIOD  = CLK_HZ / 100;          // 100 Hz PWM for inject LED
    localparam DEBOUNCE_BITS = 14;

    // -----------------------------------------------------------------------
    // Config registers (runtime tunable via 0xBC protocol)
    // -----------------------------------------------------------------------
    reg [7:0] cfg_setpoint = 8'd13;   // target sensor value (0-255)
    reg [3:0] cfg_kp       = 4'd1;    // proportional gain (0-15)
    reg [3:0] cfg_ki       = 4'd0;    // integral gain per frame, scaled (0-15)
    reg [7:0] cfg_slew     = 8'd8;    // max duty change per frame (0-255)
    reg [7:0] cfg_max_duty = 8'd255;  // upper clamp (default 255)
    reg [7:0] cfg_filter   = 8'd128;  // sensor EMA alpha (0-255, 0 = no filtering)
    reg [3:0] cfg_deadband = 4'd2;    // error deadband (0-15 counts)

    // -----------------------------------------------------------------------
    // UART receive framing
    // -----------------------------------------------------------------------
    localparam U_IDLE  = 2'd0;
    localparam U_SENSOR = 2'd1;
    localparam U_CFG_ADDR = 2'd2;
    localparam U_CFG_VAL  = 2'd3;
    reg [1:0] uart_state = U_IDLE;
    reg [7:0] cfg_addr = 8'd0;

    // -----------------------------------------------------------------------
    // Button synchroniser / debouncer
    // -----------------------------------------------------------------------
    reg [DEBOUNCE_BITS-1:0] debounce_cnt = {DEBOUNCE_BITS{1'b0}};
    reg button_sync0 = 1'b1;
    reg button_sync1 = 1'b1;
    reg button_pressed = 1'b0;

    // -----------------------------------------------------------------------
    // PI controller state
    // -----------------------------------------------------------------------
    reg signed [15:0] integrator = 16'sd0;
    reg signed [15:0] next_integrator;
    reg [7:0] duty_cmd = 8'd0;
    reg [7:0] duty_prev = 8'd0;
    reg [7:0] next_duty;
    reg [7:0] sensor = 8'd0;
    reg [7:0] sensor_filtered = 8'd0;

    // -----------------------------------------------------------------------
    // Watchdog
    // -----------------------------------------------------------------------
    reg [$clog2(WATCHDOG_LIMIT)-1:0] watchdog_cnt = {$clog2(WATCHDOG_LIMIT){1'b0}};
    reg watchdog_tripped = 1'b0;

    // -----------------------------------------------------------------------
    // Diagnostic dump FSM
    // -----------------------------------------------------------------------
    localparam DIAG_IDLE  = 2'd0;
    localparam DIAG_SEND  = 2'd1;
    localparam DIAG_WAIT  = 2'd2;
    localparam DIAG_NEXT  = 2'd3;
    reg [1:0] diag_state = DIAG_IDLE;
    reg [3:0] diag_idx = 4'd0;
    reg [7:0] diag_buf [0:15];

    // -----------------------------------------------------------------------
    // LED PWM
    // -----------------------------------------------------------------------
    reg [$clog2(PWM_PERIOD)-1:0] pwm_cnt = {$clog2(PWM_PERIOD){1'b0}};
    reg led_inject_pwm = 1'b0;

    // -----------------------------------------------------------------------
    // Combinational PI output
    // -----------------------------------------------------------------------
    reg signed [8:0] error_raw;
    reg signed [8:0] error;

    always @(*) begin
        error_raw = {1'b0, cfg_setpoint} - {1'b0, sensor_filtered};
        if (error_raw > $signed({1'b0, cfg_deadband}))
            error = error_raw - $signed({1'b0, cfg_deadband});
        else if (error_raw < -$signed({1'b0, cfg_deadband}))
            error = error_raw + $signed({1'b0, cfg_deadband});
        else
            error = 9'sd0;
    end
    wire signed [12:0] p_term = error * $signed({1'b0, cfg_kp});
    wire signed [15:0] i_term = integrator;
    wire signed [16:0] pi_sum  = {p_term[12], p_term} + {i_term[15], i_term};
    wire signed [15:0] pi_out;

    // Clamp PI sum to 0..255 before slew/rate limiting.
    assign pi_out = (pi_sum > 16'sd255) ? 16'sd255 :
                    (pi_sum < 16'sd0)   ? 16'sd0   : pi_sum[15:0];

    // Initialize diag_buf array (Gowin supports initial blocks for RAM/ROM).
    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1)
            diag_buf[i] = 8'd0;
    end

    // Synchronous-only clocking. Gowin initial values load the power-up state.
    // The previous async-reset style hung when rst_n was tied high.
    always @(posedge clk) begin
        if (!rst_n) begin
            // Software reset branch kept for simulation; tied high on board.
            uart_state     <= U_IDLE;
            tx_data        <= 8'h00;
            tx_valid       <= 1'b0;
            led_inject     <= 1'b1;
            led_stop       <= 1'b0;

            cfg_setpoint   <= 8'd13;
            cfg_kp         <= 4'd1;
            cfg_ki         <= 4'd0;
            cfg_slew       <= 8'd8;
            cfg_max_duty   <= 8'd255;
            cfg_filter     <= 8'd128;
            cfg_deadband   <= 4'd2;

            debounce_cnt   <= {DEBOUNCE_BITS{1'b0}};
            button_sync0   <= 1'b1;
            button_sync1   <= 1'b1;
            button_pressed <= 1'b0;

            integrator     <= 16'sd0;
            duty_cmd       <= 8'd0;
            duty_prev      <= 8'd0;
            sensor         <= 8'd0;

            watchdog_cnt   <= {$clog2(WATCHDOG_LIMIT){1'b0}};
            watchdog_tripped <= 1'b0;

            diag_state     <= DIAG_IDLE;
            diag_idx       <= 4'd0;

            pwm_cnt        <= {$clog2(PWM_PERIOD){1'b0}};
            led_inject_pwm <= 1'b0;

            for (i = 0; i < 16; i = i + 1)
                diag_buf[i] <= 8'd0;
        end else begin
            tx_valid <= 1'b0;

            // ----------------------------------------------------------------
            // Button debounce
            // ----------------------------------------------------------------
            button_sync0 <= button_n;
            button_sync1 <= button_sync0;
            if (debounce_cnt != {DEBOUNCE_BITS{1'b1}}) begin
                debounce_cnt <= debounce_cnt + 1'b1;
            end else begin
                button_pressed <= button_sync1;
                debounce_cnt   <= {DEBOUNCE_BITS{1'b0}};
            end

            // ----------------------------------------------------------------
            // PWM timebase for inject LED
            // ----------------------------------------------------------------
            if (pwm_cnt == PWM_PERIOD - 1)
                pwm_cnt <= {$clog2(PWM_PERIOD){1'b0}};
            else
                pwm_cnt <= pwm_cnt + 1'b1;

            led_inject_pwm <= (pwm_cnt < {duty_cmd, 2'b00});

            // ----------------------------------------------------------------
            // Watchdog
            // ----------------------------------------------------------------
            if (watchdog_cnt == WATCHDOG_LIMIT - 1) begin
                watchdog_tripped <= 1'b1;
            end else begin
                watchdog_cnt <= watchdog_cnt + 1'b1;
            end

            // ----------------------------------------------------------------
            // Diagnostic dump FSM
            // ----------------------------------------------------------------
            case (diag_state)
                DIAG_IDLE: begin
                end
                DIAG_SEND: begin
                    if (!tx_busy) begin
                        tx_data  <= diag_buf[diag_idx];
                        tx_valid <= 1'b1;
                        diag_state <= DIAG_WAIT;
                    end
                end
                DIAG_WAIT: begin
                    if (tx_busy)
                        diag_state <= DIAG_NEXT;
                end
                DIAG_NEXT: begin
                    if (!tx_busy) begin
                        if (diag_idx == 4'd15) begin
                            diag_state <= DIAG_IDLE;
                            diag_idx   <= 4'd0;
                        end else begin
                            diag_idx   <= diag_idx + 1'b1;
                            diag_state <= DIAG_SEND;
                        end
                    end
                end
                default: diag_state <= DIAG_IDLE;
            endcase

            // ----------------------------------------------------------------
            // UART frame processing
            // ----------------------------------------------------------------
            if (rx_valid) begin
                case (uart_state)
                    U_IDLE: begin
                        if (rx_data == SYNC_BYTE) begin
                            uart_state <= U_SENSOR;
                        end else if (rx_data == DIAG_SYNC) begin
                            // Restart dump even if one was in progress
                            diag_state   <= DIAG_IDLE;
                            diag_idx     <= 4'd0;
                            diag_buf[0]  <= sensor;
                            diag_buf[1]  <= sensor_filtered;
                            diag_buf[2]  <= cfg_setpoint;
                            diag_buf[3]  <= duty_cmd;
                            diag_buf[4]  <= {4'd0, cfg_kp};
                            diag_buf[5]  <= {4'd0, cfg_ki};
                            diag_buf[6]  <= cfg_slew;
                            diag_buf[7]  <= cfg_max_duty;
                            diag_buf[8]  <= cfg_filter;
                            diag_buf[9]  <= {4'd0, cfg_deadband};
                            diag_buf[10] <= watchdog_tripped ? 8'hFF : 8'h00;
                            diag_buf[11] <= button_pressed ? 8'hFF : 8'h00;
                            diag_buf[12] <= 8'd0;
                            diag_buf[13] <= 8'd0;
                            diag_buf[14] <= 8'd0;
                            diag_buf[15] <= 8'd0;
                            diag_idx     <= 4'd0;
                            diag_state   <= DIAG_SEND;
                        end else if (rx_data == CONFIG_SYNC) begin
                            uart_state <= U_CFG_ADDR;
                        end
                    end

                    U_SENSOR: begin
                        sensor          <= rx_data;
                        sensor_filtered <= (({8'd0, rx_data} * cfg_filter) +
                                            ({8'd0, sensor_filtered} * (8'd255 - cfg_filter))) >> 8;
                        uart_state      <= U_IDLE;

                        watchdog_cnt     <= {$clog2(WATCHDOG_LIMIT){1'b0}};
                        watchdog_tripped <= 1'b0;

                        // Update integrator: i_acc += ki * error
                        // ki is small (0-15), error is signed 9-bit.
                        // Clamp integrator to prevent windup.
                        if (button_pressed) begin
                            next_integrator = 16'sd0;
                        end else begin
                            next_integrator = integrator + (error * $signed({1'b0, cfg_ki}));
                            if (next_integrator > 16'sd8191)
                                next_integrator = 16'sd8191;
                            else if (next_integrator < -16'sd8192)
                                next_integrator = -16'sd8192;
                        end
                        integrator <= next_integrator;

                        // Slew / rate limit relative to previous duty.
                        if (button_pressed || watchdog_tripped) begin
                            next_duty = 8'd0;
                        end else if (pi_out > duty_prev + cfg_slew) begin
                            next_duty = duty_prev + cfg_slew;
                        end else if (pi_out < duty_prev - cfg_slew) begin
                            next_duty = duty_prev - cfg_slew;
                        end else begin
                            next_duty = pi_out[7:0];
                        end

                        // Final clamps.
                        if (next_duty > cfg_max_duty)
                            next_duty = cfg_max_duty;

                        duty_cmd  <= next_duty;
                        duty_prev <= next_duty;

                        // Reply to host with the duty we are using.
                        if (diag_state == DIAG_IDLE) begin
                            tx_data  <= next_duty;
                            tx_valid <= 1'b1;
                        end
                    end

                    U_CFG_ADDR: begin
                        cfg_addr   <= rx_data;
                        uart_state <= U_CFG_VAL;
                    end

                    U_CFG_VAL: begin
                        case (cfg_addr)
                            8'd0: cfg_setpoint <= rx_data;
                            8'd1: cfg_kp       <= rx_data[3:0];
                            8'd2: cfg_ki       <= rx_data[3:0];
                            8'd3: cfg_slew     <= rx_data;
                            8'd4: cfg_max_duty <= rx_data;
                            8'd5: cfg_filter   <= rx_data;
                            8'd6: cfg_deadband <= rx_data[3:0];
                            default: ;
                        endcase
                        uart_state <= U_IDLE;
                        if (diag_state == DIAG_IDLE) begin
                            tx_data  <= rx_data;
                            tx_valid <= 1'b1;
                        end
                    end

                    default: uart_state <= U_IDLE;
                endcase
            end

            // ----------------------------------------------------------------
            // LED outputs
            // ----------------------------------------------------------------
            if (button_pressed) begin
                led_inject <= 1'b1;
                led_stop   <= 1'b0;
            end else if (watchdog_tripped) begin
                led_inject <= 1'b1;
                led_stop   <= 1'b0;
            end else if (duty_cmd == 0) begin
                led_inject <= 1'b1;
                led_stop   <= 1'b0;
            end else begin
                led_inject <= ~led_inject_pwm;
                led_stop   <= 1'b1;
            end
        end
    end

endmodule
