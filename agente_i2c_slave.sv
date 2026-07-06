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

    function new(virtual i2c_if i2c_s_if);
        this.i2c_s_if = i2c_s_if;
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
        $display("I2C Slave: Start condition detected");
    endtask

    task automatic receive_addr_rw();
        addr_rw = 0;
        for (int i=0; i<8; ++i) begin
            @(posedge i2c_s_if.scl);
            addr_rw = addr_rw << 1 | i2c_s_if.sda;
        end
        $display("I2C Slave: Received address_rw = %h r(1)w(0) = %b", addr_rw[7:1], addr_rw[0]);
    endtask

    task automatic gen_ack();
        @(negedge i2c_s_if.scl);
        drive_sda_low();
        @(posedge i2c_s_if.scl);
        #3us;
        release_sda();
        $display("I2C Slave: ACK generated");
    endtask

    task automatic recv_ack();

        @(posedge i2c_s_if.scl);

        $display("I2C Slave: ACK received = %b", i2c_s_if.sda);
    endtask    

    task automatic wait_stop();
        @(posedge i2c_s_if.sda iff (i2c_s_if.scl));
        $display("I2C Slave: Stop condition detected");
    endtask

    task automatic receive_data();
        data = 0;
        for (int i=0; i<8; ++i) begin
            @(posedge i2c_s_if.scl);
            data = data << 1 | i2c_s_if.sda;
        end
        $display("I2C Slave: Received data = %h", data);
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
        $display("I2C Slave: Sent data = %h", data);
    endtask

    task automatic receive_data_or_stop(output logic got_data);
        got_data = 1'b0;
        fork : data_or_stop
            begin
                receive_data();
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

        forever begin
            release_bus();
            wait_start();
            receive_addr_rw();
            gen_ack();

            if (!addr_rw[0]) begin
                do begin
                    receive_data_or_stop(got_data);
                    if (got_data) begin
                        gen_ack();
                    end
                end while (got_data);
            end else begin
                do begin
                    write_data_or_stop(8'b00110101, got_data);
                    if (got_data) begin
                        recv_ack();
                    end
                end while (got_data);
            end
        end

    endtask
    
endclass
