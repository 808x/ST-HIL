module uart_tx (
    input wire clk,
    input wire rst_n,
    input wire [7:0] data,
    input wire data_valid,
    output reg tx,
    output reg busy
);

    localparam CLK_DIV = 234; // 27 MHz / 115200 baud

    reg [2:0] state;
    reg [8:0] bit_timer;
    reg [3:0] bit_count;
    reg [7:0] shift_reg;

    localparam IDLE  = 3'd0;
    localparam START = 3'd1;
    localparam DATA  = 3'd2;
    localparam STOP  = 3'd3;
    localparam DONE  = 3'd4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            bit_timer <= 9'd0;
            bit_count <= 4'd0;
            shift_reg <= 8'd0;
            tx        <= 1'b1;
            busy      <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    if (data_valid && !busy) begin
                        state     <= START;
                        shift_reg <= data;
                        busy      <= 1'b1;
                        bit_timer <= 9'd0;
                    end
                end

                START: begin
                    tx <= 1'b0;
                    if (bit_timer == CLK_DIV) begin
                        state     <= DATA;
                        bit_timer <= 9'd0;
                        bit_count <= 4'd0;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                DATA: begin
                    tx <= shift_reg[0];
                    if (bit_timer == CLK_DIV) begin
                        bit_timer <= 9'd0;
                        shift_reg <= {1'b0, shift_reg[7:1]};
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
                    tx <= 1'b1;
                    if (bit_timer == CLK_DIV) begin
                        state     <= DONE;
                        bit_timer <= 9'd0;
                    end else begin
                        bit_timer <= bit_timer + 1'b1;
                    end
                end

                DONE: begin
                    busy  <= 1'b0;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
