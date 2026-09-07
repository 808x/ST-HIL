module top (
    input wire clk,
    input wire uart_rx,
    output wire uart_tx,
    input wire button_n,
    output wire led_inject,
    output wire led_stop
);

    wire rst_n = 1'b1;

    wire [7:0] rx_data;
    wire       rx_valid;
    wire [7:0] tx_data;
    wire       tx_valid;
    wire       tx_busy;

    uart_rx uart_rx_inst (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx        (uart_rx),
        .data      (rx_data),
        .data_valid(rx_valid)
    );

    species_fsm species_fsm_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        .button_n   (button_n),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .tx_busy    (tx_busy),
        .tx_data    (tx_data),
        .tx_valid   (tx_valid),
        .led_inject (led_inject),
        .led_stop   (led_stop)
    );

    uart_tx uart_tx_inst (
        .clk       (clk),
        .rst_n     (rst_n),
        .data      (tx_data),
        .data_valid(tx_valid),
        .tx        (uart_tx),
        .busy      (tx_busy)
    );

endmodule
