module uart_rx (
    input wire clk,
    input wire rst_n,
    input wire rx,
    output reg [7:0] data,
    output reg data_valid
);

    localparam CLK_DIV = 234; // 27 MHz / 115200 baud
    localparam HALF_DIV = CLK_DIV / 2;

    reg [2:0] state;
    reg [8:0] bit_timer;
    reg [3:0] bit_count;
    reg [7:0] shift_reg;
    reg rx_sync0, rx_sync1;

    localparam IDLE  = 3'd0;
    localparam START = 3'd1;
    localparam DATA  = 3'd2;
    localparam STOP  = 3'd3;
    localparam DONE  = 3'd4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync0 <= 1'b1;
            rx_sync1 <= 1'b1;
        end else begin
            rx_sync0 <= rx;
            rx_sync1 <= rx_sync0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            bit_timer  <= 9'd0;
            bit_count  <= 4'd0;
            shift_reg  <= 8'd0;
            data       <= 8'd0;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0;

            case (state)
                IDLE: begin
                    if (rx_sync1 == 1'b0) begin
                        state     <= START;
                        bit_timer <= 9'd0;
                    end
                end

                START: begin
                    if (bit_timer == HALF_DIV) begin
                        state     <= DATA;
                        bit_timer <= 9'd0;
                        bit_count <= 4'd0;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                DATA: begin
                    if (bit_timer == CLK_DIV) begin
                        bit_timer <= 9'd0;
                        shift_reg <= {rx_sync1, shift_reg[7:1]};
                        if (bit_count == 4'd7) begin
                            state <= STOP;
                        end else begin
                            bit_count <= bit_count + 1'b1;
                        end
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                STOP: begin
                    if (bit_timer == CLK_DIV) begin
                        state      <= DONE;
                        bit_timer  <= 9'd0;
                        data       <= shift_reg;
                        data_valid <= 1'b1;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                DONE: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
