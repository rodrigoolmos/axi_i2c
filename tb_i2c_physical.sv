`timescale 1ns/1ps

`include "agente_i2c_slave.sv"

module tb_i2c_physical;

    // ----------------------------
    // Parámetros TB
    // ----------------------------
    localparam int CLOCK_FREQ_HZ = 100_000_000;
    localparam time CLK_PERIOD   = 10ns; // 100 MHz

    // ----------------------------
    // Señales DUT
    // ----------------------------
    logic        clk;
    logic        nrst;

    logic        ena;
    logic        new_byte;
    logic        system_idle;
    logic [7:0]  addr_rw;
    logic [7:0]  data_in;
    logic [7:0]  data_out;
    logic        error_ack;

    // ----------------------------
    // I2C slave agent
    // ----------------------------
    i2c_if i2c_bus();
    i2c_slave slave_agent;

    // ----------------------------
    // DUT instancia
    // ----------------------------
    i2c_physical #(
        .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ)
    ) dut (
        .clk        (clk),
        .nrst       (nrst),
        .ena        (ena),
        .new_byte   (new_byte),
        .system_idle(system_idle),
        .addr_rw    (addr_rw),
        .data_in    (data_in),
        .data_out   (data_out),
        .error_ack  (error_ack),
        .i2c_scl    (i2c_bus.scl),
        .i2c_sda    (i2c_bus.sda)
    );

    // ----------------------------
    // Clock / Reset
    // ----------------------------
    initial clk = 0;
        always #(CLK_PERIOD/2) clk = ~clk;

    task automatic apply_reset();
        begin
        nrst = 0;
        ena  = 0;
        addr_rw  = 8'h00;
        data_in  = 8'h00;
        i2c_bus.slave_scl_drive_low = 0;
        i2c_bus.slave_sda_drive_low = 0;
        repeat (10) @(posedge clk);
        nrst = 1;
        repeat (5) @(posedge clk);
        end
    endtask

    task write_address_rw(input logic [6:0] addr, logic rw);
        begin
            addr_rw = {addr, rw};
            ena = 1;
            @(posedge clk);
        end
    endtask

    task write_data(input logic [7:0] data);
        begin
            data_in = data;
            ena = 1;
            @(posedge clk iff (new_byte));
            ena = 0;
        end
    endtask

    task read_data(output logic[7:0] data);
        begin
            data = 0;
            ena = 1;
            @(posedge clk iff (new_byte));
            ena = 0;
        end
    endtask

    initial begin
        logic[7:0] data_out;
        slave_agent = new(i2c_bus);
        slave_agent.release_bus();
        fork
            slave_agent.receive();
        join_none

        apply_reset();
        write_address_rw(7'h3A, 1'b0);
        write_data(8'h55);
        write_data(8'h11);
        write_data(8'h22);

        @(posedge clk iff system_idle);
        #100000ns;
        @(posedge clk);

        write_address_rw(7'h3A, 1'b1);
        read_data(data_out);
        $display("I2c Master: Read data: %h", data_out);

        #100000ns;
        $finish;
    end

endmodule
