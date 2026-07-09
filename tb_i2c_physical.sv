`timescale 1ns/1ps

`include "agente_i2c_slave.sv"

module tb_i2c_physical;

    // ----------------------------
    // Parámetros TB
    // ----------------------------
    localparam int CLOCK_FREQ_HZ = 100_000_000;
    localparam time CLK_PERIOD   = 10ns; // 100 MHz
    localparam int NUM_TEST_ADDRS = 128;
    localparam int MIN_BYTES_PER_ADDR = 1;
    localparam int MAX_BYTES_PER_ADDR = 4;
    localparam int WAIT_TIMEOUT_CYCLES = 2_000_000;
    localparam string LOG_FILE = "i2c_physical_test.log";

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

    logic [7:0] golden_mem[logic [6:0]][$];
    logic [7:0] read_mem[logic [6:0]][$];
    int log_fd;

    // ----------------------------
    // I2C slave agent
    // ----------------------------
    i2c_if i2c_bus();
    i2c_slave slave_agent;
    process slave_proc;

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

    i2c_protocol_checker #(
        .CLOCK_FREQ_HZ(CLOCK_FREQ_HZ)
    ) i2c_checker (
        .clk (clk),
        .nrst(nrst),
        .scl (i2c_bus.scl),
        .sda (i2c_bus.sda)
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

    task automatic write_address_rw(input logic [6:0] addr, input logic rw);
        begin
            addr_rw = {addr, rw};
            ena = 1;
            @(posedge clk);
        end
    endtask

    task automatic write_data(input logic [7:0] data, input logic last_byte);
        bit done;
        begin
            data_in = data;
            ena = 1;
            done = 0;
            for (int i=0; i<WAIT_TIMEOUT_CYCLES && !done; ++i) begin
                @(posedge clk);
                done = new_byte;
            end
            if (!done) begin
                tb_log("I2C TB: FAIL write_data timeout waiting new_byte");
                $fatal(1, "I2C TB: write_data timeout waiting new_byte");
            end
            ena = !last_byte;
        end
    endtask

    task automatic read_data(output logic[7:0] data, input logic last_byte);
        bit done;
        begin
            data = 0;
            ena = 1;
            done = 0;
            for (int i=0; i<WAIT_TIMEOUT_CYCLES && !done; ++i) begin
                @(posedge clk);
                done = new_byte;
            end
            if (!done) begin
                tb_log("I2C TB: FAIL read_data timeout waiting new_byte");
                $fatal(1, "I2C TB: read_data timeout waiting new_byte");
            end
            data = data_out;
            ena = !last_byte;
        end
    endtask

    task automatic send_transaction(input logic[6:0] addr,
                                    input logic read_nwrite,
                                    ref logic [7:0] data[],
                                    input int num_bytes);
        begin
            write_address_rw(addr, read_nwrite);
            for (int i=0; i<num_bytes; ++i) begin
                if (!read_nwrite) begin
                    write_data(data[i], i == num_bytes - 1);
                end else begin
                    read_data(data[i], i == num_bytes - 1);
                end
            end
        end
    endtask

    task automatic init_golden_mem();
        int n_data_addr;
        logic [6:0] addr;

        golden_mem.delete();
        read_mem.delete();

        for (int i=0; i<NUM_TEST_ADDRS; ++i) begin
            addr = i;
            n_data_addr = $urandom_range(MIN_BYTES_PER_ADDR, MAX_BYTES_PER_ADDR);
            for (int j=0; j<n_data_addr; ++j) begin
                golden_mem[addr].push_back($urandom_range(0, 255));
            end
        end
    endtask

    task automatic tb_log(input string msg);
        if (log_fd != 0) begin
            $fdisplay(log_fd, "[%0t] %s", $time, msg);
            $fflush(log_fd);
        end
    endtask

    task automatic verify_integrity_golden_read_mem();
        int errors;
        int expected_size;
        int actual_size;
        logic [6:0] addr;

        errors = 0;
        for (int i=0; i<NUM_TEST_ADDRS; ++i) begin
            addr = i;
            expected_size = golden_mem[addr].size();
            actual_size = read_mem[addr].size();

            if (actual_size != expected_size) begin
                tb_log($sformatf("I2C TB: addr=%h size mismatch expected=%0d actual=%0d",
                                 addr, expected_size, actual_size));
                errors++;
            end

            for (int j=0; j<expected_size && j<actual_size; ++j) begin
                if (read_mem[addr][j] !== golden_mem[addr][j]) begin
                    tb_log($sformatf("I2C TB: addr=%h byte[%0d] mismatch expected=%h actual=%h",
                                     addr, j, golden_mem[addr][j], read_mem[addr][j]));
                    errors++;
                end
            end
        end

        if (errors == 0) begin
            tb_log("I2C TB: PASS shadow_mem write/read integrity");
        end else begin
            tb_log($sformatf("I2C TB: FAIL shadow_mem write/read integrity errors=%0d", errors));
            $display("I2C TB: FAIL shadow_mem write/read integrity errors=%0d log=%s", errors, LOG_FILE);
            $fatal(1);
        end
    endtask

    task automatic wait_complete();
        bit done;
        done = 0;
        for (int i=0; i<WAIT_TIMEOUT_CYCLES && !done; ++i) begin
            @(posedge clk);
            done = system_idle;
        end

        if (!done) begin
            tb_log("I2C TB: FAIL wait_complete timeout");
            $fatal(1, "I2C TB: wait_complete timeout");
        end

        #100000ns;
        @(posedge clk);
    endtask

    task automatic start_slave_agent();
        if (slave_proc != null) begin
            slave_proc.kill();
        end
        slave_agent.release_bus();
        fork
            begin
                slave_proc = process::self();
                slave_agent.receive();
            end
        join_none
    endtask

    task automatic expect_error_ack(input string test_name);
        bit seen_error_ack;
        bit done;
        seen_error_ack = 0;
        done = 0;

        for (int i=0; i<WAIT_TIMEOUT_CYCLES && !done; ++i) begin
            @(posedge clk);
            if (error_ack) begin
                seen_error_ack = 1;
            end
            done = system_idle;
        end

        if (!seen_error_ack) begin
            tb_log($sformatf("I2C TB: FAIL %s expected error_ack", test_name));
            $fatal(1, "I2C TB: FAIL %s expected error_ack", test_name);
        end
        tb_log($sformatf("I2C TB: PASS %s observed error_ack", test_name));

        if (!done) begin
            wait_complete();
        end else begin
            #100000ns;
            @(posedge clk);
        end
    endtask

    task automatic send_write_transaction(input logic [6:0] addr, input logic [7:0] values[]);
        int num_bytes;
        num_bytes = values.size();
        send_transaction(addr, 1'b0, values, num_bytes);
        wait_complete();
    endtask

    task automatic send_read_transaction(input logic [6:0] addr, ref logic [7:0] values[]);
        int num_bytes;
        num_bytes = values.size();
        send_transaction(addr, 1'b1, values, num_bytes);
        wait_complete();
    endtask

    task automatic test_nack_address();
        tb_log("I2C TB: starting test_nack_address");
        slave_agent.set_nack_next_addr();
        write_address_rw(7'h55, 1'b0);
        ena = 0;
        expect_error_ack("test_nack_address");
    endtask

    task automatic test_nack_data();
        logic [7:0] data_tmp[];
        tb_log("I2C TB: starting test_nack_data");
        data_tmp = new[1];
        data_tmp[0] = 8'ha5;
        slave_agent.set_nack_next_data();
        write_address_rw(7'h56, 1'b0);
        write_data(data_tmp[0], 1'b1);
        expect_error_ack("test_nack_data");
    endtask

    task automatic test_clock_stretching();
        logic [7:0] wr_data[];
        logic [7:0] rd_data[];
        tb_log("I2C TB: starting test_clock_stretching");

        wr_data = new[3];
        wr_data[0] = 8'hc3;
        wr_data[1] = 8'h3c;
        wr_data[2] = 8'h81;
        rd_data = new[3];

        slave_agent.set_stretch_time(8us);
        send_write_transaction(7'h60, wr_data);
        send_read_transaction(7'h60, rd_data);
        slave_agent.set_stretch_time(0ns);

        for (int i=0; i<wr_data.size(); ++i) begin
            if (rd_data[i] !== wr_data[i]) begin
                tb_log($sformatf("I2C TB: FAIL test_clock_stretching byte[%0d] expected=%h actual=%h", i, wr_data[i], rd_data[i]));
                $fatal(1, "I2C TB: FAIL test_clock_stretching");
            end
        end
        tb_log("I2C TB: PASS test_clock_stretching");
    endtask

    task automatic test_input_latching();
        logic [7:0] data_tmp[];
        logic [7:0] read_tmp[];
        tb_log("I2C TB: starting test_input_latching");
        data_tmp = new[2];
        data_tmp[0] = 8'h12;
        data_tmp[1] = 8'h34;
        read_tmp = new[2];

        write_address_rw(7'h61, 1'b0);
        repeat (20) begin
            @(posedge clk);
            addr_rw = $urandom_range(0, 255);
        end

        data_in = data_tmp[0];
        ena = 1;
        @(posedge clk iff dut.i2c_status == dut.DATA);
        repeat (20) begin
            @(posedge clk);
            data_in = $urandom_range(0, 255);
            addr_rw = $urandom_range(0, 255);
        end
        @(posedge clk iff new_byte);
        ena = 1;

        @(posedge clk iff dut.i2c_status == dut.WRITE_ACK);
        data_in = data_tmp[1];
        @(posedge clk iff dut.i2c_status == dut.DATA);
        repeat (20) begin
            @(posedge clk);
            data_in = $urandom_range(0, 255);
            addr_rw = $urandom_range(0, 255);
        end
        @(posedge clk iff new_byte);
        ena = 0;
        wait_complete();

        send_read_transaction(7'h61, read_tmp);
        for (int i=0; i<data_tmp.size(); ++i) begin
            if (read_tmp[i] !== data_tmp[i]) begin
                tb_log($sformatf("I2C TB: FAIL test_input_latching byte[%0d] expected=%h actual=%h", i, data_tmp[i], read_tmp[i]));
                $fatal(1, "I2C TB: FAIL test_input_latching");
            end
        end
        tb_log("I2C TB: PASS test_input_latching");
    endtask

    task automatic test_reset_mid_transaction();
        tb_log("I2C TB: starting test_reset_mid_transaction");
        addr_rw = {7'h62, 1'b0};
        data_in = 8'hdb;
        ena = 1;
        repeat (250) @(posedge clk);
        nrst = 0;
        ena = 0;
        addr_rw = 8'h00;
        data_in = 8'h00;
        slave_agent.release_bus();
        repeat (10) @(posedge clk);
        nrst = 1;
        repeat (10) @(posedge clk);
        start_slave_agent();

        if (!system_idle) begin
            @(posedge clk iff system_idle);
        end
        tb_log("I2C TB: PASS test_reset_mid_transaction");
    endtask

    initial begin
        logic[7:0] data_tmp[];
        logic[6:0] addr_tmp;
        logic read_nwrite_tmp;
        int num_bytes_tmp;

        log_fd = $fopen(LOG_FILE, "w");
        if (log_fd == 0) begin
            $fatal(1, "I2C TB: could not open log file %s", LOG_FILE);
        end
        tb_log("I2C TB: starting shadow_mem write/read test");

        slave_agent = new(i2c_bus);
        slave_agent.set_log_fd(log_fd);
        start_slave_agent();
        apply_reset();

        test_reset_mid_transaction();
        test_nack_address();
        test_nack_data();
        test_clock_stretching();
        test_input_latching();

        init_golden_mem();

        // send all golden memory transactions
        for (int i=0; i<NUM_TEST_ADDRS; ++i) begin
            addr_tmp = i;
            num_bytes_tmp = golden_mem[addr_tmp].size();
            if (num_bytes_tmp > 0) begin
                data_tmp = new[num_bytes_tmp];
                for (int j=0; j<num_bytes_tmp; ++j) begin
                    data_tmp[j] = golden_mem[addr_tmp][j];
                end
                read_nwrite_tmp = 0; // write
                send_transaction(addr_tmp, read_nwrite_tmp, data_tmp, num_bytes_tmp);
                wait_complete();
            end
        end

        // read all golden memory transactions
        for (int i=0; i<NUM_TEST_ADDRS; ++i) begin
            addr_tmp = i;
            num_bytes_tmp = golden_mem[addr_tmp].size();
            if (num_bytes_tmp > 0) begin
                data_tmp = new[num_bytes_tmp];
                read_nwrite_tmp = 1; // read
                send_transaction(addr_tmp, read_nwrite_tmp, data_tmp, num_bytes_tmp);
                wait_complete();
                for (int j=0; j<num_bytes_tmp; ++j) begin
                    read_mem[addr_tmp].push_back(data_tmp[j]);
                end
            end
        end

        verify_integrity_golden_read_mem();
        tb_log("I2C TB: finished shadow_mem write/read test");
        tb_log("I2C TB: PASS all tests");
        $display("I2C TB: PASS all tests");
        $fclose(log_fd);

        #100000ns;
        $finish;
    end

endmodule
