interface i2c_if;

    tri1 sda;
    tri1 scl;

    logic slave_sda_drive_low;
    logic slave_scl_drive_low;

    assign sda = slave_sda_drive_low ? 1'b0 : 1'bz;
    assign scl = slave_scl_drive_low ? 1'b0 : 1'bz;
    
endinterface

class i2c_slave;

    virtual i2c_if i2c_s_if;
    logic[7:0] addr_rw;
    logic[7:0] data;
    int log_fd;
    bit nack_next_addr;
    bit nack_next_data;
    time stretch_time;

    logic [7:0] shadow_mem[logic [6:0]][$];

    function new(virtual i2c_if i2c_s_if);
        this.i2c_s_if = i2c_s_if;
        this.log_fd = 0;
        this.nack_next_addr = 0;
        this.nack_next_data = 0;
        this.stretch_time = 0ns;
    endfunction

    function void set_log_fd(int log_fd);
        this.log_fd = log_fd;
    endfunction

    function void write_log(string msg);
        if (log_fd != 0) begin
            $fdisplay(log_fd, "[%0t] %s", $time, msg);
        end
    endfunction

    function void set_nack_next_addr(bit value = 1'b1);
        nack_next_addr = value;
    endfunction

    function void set_nack_next_data(bit value = 1'b1);
        nack_next_data = value;
    endfunction

    function void set_stretch_time(time value);
        stretch_time = value;
    endfunction

    task automatic release_bus();
        i2c_s_if.slave_sda_drive_low = 1'b0;
        i2c_s_if.slave_scl_drive_low = 1'b0;
    endtask

    task automatic drive_sda_low();
        i2c_s_if.slave_sda_drive_low = 1'b1;
    endtask

    task automatic release_sda();
        i2c_s_if.slave_sda_drive_low = 1'b0;
    endtask

    task automatic drive_scl_low();
        i2c_s_if.slave_scl_drive_low = 1'b1;
    endtask

    task automatic release_scl();
        i2c_s_if.slave_scl_drive_low = 1'b0;
    endtask

    task automatic wait_start();
        @(negedge i2c_s_if.sda iff (i2c_s_if.scl));
        write_log("I2C Slave: Start condition detected");
    endtask

    task automatic maybe_stretch_scl();
        if (stretch_time != 0ns) begin
            drive_scl_low();
            #(stretch_time);
            release_scl();
            write_log($sformatf("I2C Slave: SCL stretched for %0t", stretch_time));
        end
    endtask

    task automatic receive_addr_rw(output logic [6:0] addr, output logic r_nw);
        addr_rw = 0;
        for (int i=0; i<8; ++i) begin
            @(posedge i2c_s_if.scl);
            addr_rw = addr_rw << 1 | i2c_s_if.sda;
        end
        addr = addr_rw[7:1];
        r_nw = addr_rw[0];
        write_log($sformatf("I2C Slave: Received address_rw = %h r(1)w(0) = %b", addr, r_nw));
    endtask

    task automatic gen_ack();
        @(negedge i2c_s_if.scl);
        drive_sda_low();
        maybe_stretch_scl();
        @(negedge i2c_s_if.scl);
        release_sda();
        write_log("I2C Slave: ACK generated");
    endtask

    task automatic gen_nack();
        @(negedge i2c_s_if.scl);
        release_sda();
        maybe_stretch_scl();
        @(negedge i2c_s_if.scl);
        release_sda();
        write_log("I2C Slave: NACK generated");
    endtask

    task automatic recv_ack(output logic got_ack);

        @(posedge i2c_s_if.scl);
        if (i2c_s_if.sda) begin
            got_ack = 1'b0;
            write_log("I2C Slave: NACK received");
        end else begin
            got_ack = 1'b1;
            write_log("I2C Slave: ACK received");
        end
        @(negedge i2c_s_if.scl);
    endtask    

    task automatic wait_stop();
        @(posedge i2c_s_if.sda iff (i2c_s_if.scl));
        write_log("I2C Slave: Stop condition detected");
    endtask

    task automatic push_shadow_mem(input logic [6:0] addr, input logic [7:0] value);
        begin
            shadow_mem[addr].push_back(value);
            write_log($sformatf("I2C Slave: shadow_mem[%h] <= %h depth=%0d", addr, value, shadow_mem[addr].size()));
        end
    endtask

    task automatic peek_shadow_mem(input logic [6:0] addr, output logic [7:0] value);
        begin
            value = 8'h00;
            if (shadow_mem.exists(addr) && shadow_mem[addr].size() != 0) begin
                value = shadow_mem[addr][0];
                write_log($sformatf("I2C Slave: shadow_mem[%h] -> %h depth=%0d", addr, value, shadow_mem[addr].size()));
            end else begin
                write_log($sformatf("I2C Slave: shadow_mem[%h] empty, sending %h", addr, value));
            end
        end
    endtask

    task automatic pop_shadow_mem(input logic [6:0] addr);
        logic [7:0] value;
        begin
            if (shadow_mem.exists(addr) && shadow_mem[addr].size() != 0) begin
                value = shadow_mem[addr].pop_front();
                write_log($sformatf("I2C Slave: shadow_mem[%h] consumed %h depth=%0d", addr, value, shadow_mem[addr].size()));
            end
        end
    endtask

    task automatic receive_data(output logic [7:0] value);
        value = 0;
        for (int i=0; i<8; ++i) begin
            @(posedge i2c_s_if.scl);
            value = value << 1 | i2c_s_if.sda;
        end
        write_log($sformatf("I2C Slave: Received data = %h", value));
    endtask

    task automatic write_data(input logic [7:0] data);
        for (int i=0; i<8; ++i) begin
            if(data[7-i]) begin
                release_sda();
            end else begin
                drive_sda_low();
            end
            @(negedge i2c_s_if.scl);
        end
        release_sda();
        write_log($sformatf("I2C Slave: Sent data = %h", data));
    endtask

    task automatic receive_data_or_stop(output logic got_data, output logic [7:0] value);
        got_data = 1'b0;
        value = 0;
        fork : data_or_stop
            begin
                receive_data(value);
                got_data = 1'b1;
            end

            begin
                wait_stop();
                got_data = 1'b0;
            end
        join_any

        disable data_or_stop;
    endtask

    task automatic write_data_or_stop(input logic[7:0] data, output logic got_data);
        got_data = 1'b0;
        fork : data_or_stop
            begin
                write_data(data);
                got_data = 1'b1;
            end

            begin
                wait_stop();
                got_data = 1'b0;
            end
        join_any

        disable data_or_stop;
    endtask

    task automatic receive();
        logic got_data;
        logic got_ack;
        logic [6:0] addr;
        logic r_nw;
        logic [7:0] tx_data;
        logic [7:0] rx_data;

        forever begin
            release_bus();
            wait_start();
            receive_addr_rw(addr, r_nw);
            if (nack_next_addr) begin
                nack_next_addr = 0;
                gen_nack();
                wait_stop();
                continue;
            end else begin
                gen_ack();
            end

            if (!addr_rw[0]) begin
                do begin
                    receive_data_or_stop(got_data, rx_data);
                    if (got_data) begin
                        if (nack_next_data) begin
                            nack_next_data = 0;
                            gen_nack();
                        end else begin
                            push_shadow_mem(addr, rx_data);
                            write_log($sformatf("I2C Slave: Accepted data = %h addr = %h", rx_data, addr));
                            gen_ack();
                        end
                    end
                end while (got_data);
            end else begin
                do begin
                    peek_shadow_mem(addr, tx_data);
                    write_data_or_stop(tx_data, got_data);
                    if (got_data) begin
                        pop_shadow_mem(addr);
                        recv_ack(got_ack);
                    end
                end while (got_data && got_ack);

                if (got_data && !got_ack) begin
                    wait_stop();
                end
            end
        end

    endtask
    
endclass
