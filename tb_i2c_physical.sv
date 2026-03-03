`timescale 1ns/1ps

module tb_i2c_physical;

  // ----------------------------
  // Parámetros TB
  // ----------------------------
  localparam int CLOCK_FREQ_HZ = 100_000_000;
  localparam time CLK_PERIOD   = 10ns; // 100 MHz

  // I2C modes
  localparam logic [1:0] MODE_100K = 2'b00;
  localparam logic [1:0] MODE_400K = 2'b01;
  localparam logic [1:0] MODE_1M   = 2'b10;

  // ----------------------------
  // Señales DUT
  // ----------------------------
  logic        clk;
  logic        nrst;

  logic        ena;
  logic        new_byte;
  logic [1:0]  i2c_mode;
  logic        system_idle;
  logic [7:0]  addr_rw;
  logic [7:0]  data_in;
  logic [7:0]  data_out;
  logic        error_ack;

  tri1         i2c_scl;   // pull-up implícita (tri1)
  tri1         i2c_sda;

  // ----------------------------
  // Open-drain drivers (TB side)
  // ----------------------------
  logic scl_slave_drive_low;
  logic sda_slave_drive_low;

  assign i2c_scl = (scl_slave_drive_low) ? 1'b0 : 1'bz;
  assign i2c_sda = (sda_slave_drive_low) ? 1'b0 : 1'bz;

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
    .i2c_mode   (i2c_mode),
    .system_idle(system_idle),
    .addr_rw    (addr_rw),
    .data_in    (data_in),
    .data_out   (data_out),
    .error_ack  (error_ack),
    .i2c_scl    (i2c_scl),
    .i2c_sda    (i2c_sda)
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
      i2c_mode = MODE_100K;
      addr_rw  = 8'h00;
      data_in  = 8'h00;
      scl_slave_drive_low = 0;
      sda_slave_drive_low = 0;
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
        ena = 0;
    end
  endtask

  initial begin
    apply_reset();
    write_address_rw(7'h3A, 1'b0);

    #100000ns;
    $finish;
  end

endmodule