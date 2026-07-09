module i2c_protocol_checker #(
    parameter unsigned CLOCK_FREQ_HZ = 100_000_000,
    parameter unsigned CNT_LOW_MIN   = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000,
    parameter unsigned CNT_HIGH_MIN  = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000
) (
    input logic clk,
    input logic nrst,
    input logic scl,
    input logic sda
);

    localparam int LOW_MIN_CHECK  = (CNT_LOW_MIN  > 1) ? int'(CNT_LOW_MIN  - 1) : 1;
    localparam int HIGH_MIN_CHECK = (CNT_HIGH_MIN > 1) ? int'(CNT_HIGH_MIN - 1) : 1;

    logic scl_q;
    logic sda_q;
    logic in_transfer;
    logic start_seen;
    logic stop_seen;
    logic scl_rise_seen;
    logic scl_fall_seen;
    logic byte_complete_seen;
    logic ack_known_seen;
    logic start_in_transfer;
    logic stop_in_transfer;
    logic stop_ready;
    logic stop_setup_seen;
    logic sda_high_change_seen;
    int unsigned byte_complete_byte_cnt;
    int unsigned low_count_at_rise;
    int unsigned high_count_at_fall;
    int unsigned bit_cnt;
    int unsigned scl_low_cnt;
    int unsigned scl_high_cnt;
    int unsigned byte_cnt;

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            scl_q <= 1;
            sda_q <= 1;
            in_transfer <= 0;
            start_seen <= 0;
            stop_seen <= 0;
            scl_rise_seen <= 0;
            scl_fall_seen <= 0;
            byte_complete_seen <= 0;
            ack_known_seen <= 0;
            start_in_transfer <= 0;
            stop_in_transfer <= 0;
            stop_ready <= 0;
            stop_setup_seen <= 0;
            sda_high_change_seen <= 0;
            byte_complete_byte_cnt <= 0;
            low_count_at_rise <= 0;
            high_count_at_fall <= 0;
            bit_cnt <= 0;
            byte_cnt <= 0;
            scl_low_cnt <= 0;
            scl_high_cnt <= 0;
        end else begin
            if (scl && !sda_q && sda) begin
                assert (bit_cnt == 0 || bit_cnt == 8 || (bit_cnt == 1 && stop_setup_seen))
                    else $fatal(1, "I2C protocol violation: STOP before a complete 8-bit byte plus ACK at time %0t bit_cnt=%0d byte_cnt=%0d", $time, bit_cnt, byte_cnt);
            end

            start_seen <= scl && sda_q && !sda;
            stop_seen <= scl && !sda_q && sda;
            scl_rise_seen <= scl && !scl_q;
            scl_fall_seen <= !scl && scl_q;
            byte_complete_seen <= in_transfer && !(scl && sda_q && !sda) &&
                                  !(scl && !sda_q && sda) &&
                                  scl && !scl_q && (bit_cnt == 8);
            ack_known_seen <= !$isunknown(sda);
            start_in_transfer <= in_transfer;
            stop_in_transfer <= in_transfer;
            sda_high_change_seen <= in_transfer && scl && scl_q && (sda != sda_q) &&
                                    !(scl && !sda_q && sda);
            byte_complete_byte_cnt <= byte_cnt;
            if (scl && !scl_q) begin
                low_count_at_rise <= scl_low_cnt;
            end
            if (!scl && scl_q) begin
                high_count_at_fall <= scl_high_cnt;
            end

            if (scl && sda_q && !sda) begin
                stop_ready <= 0;
                stop_setup_seen <= 0;
            end else if (scl && !sda_q && sda) begin
                stop_ready <= 0;
                stop_setup_seen <= 0;
            end else if (in_transfer && !(scl && sda_q && !sda) &&
                         !(scl && !sda_q && sda) &&
                         scl && !scl_q && (bit_cnt == 8)) begin
                stop_ready <= 1;
                stop_setup_seen <= 0;
            end else if (stop_ready && scl && !scl_q && !sda) begin
                stop_setup_seen <= 1;
            end else if (stop_setup_seen && !scl && scl_q) begin
                stop_ready <= 0;
                stop_setup_seen <= 0;
            end

            scl_q <= scl;
            sda_q <= sda;

            if (scl) begin
                scl_high_cnt <= scl_high_cnt + 1;
                scl_low_cnt <= 0;
            end else begin
                scl_low_cnt <= scl_low_cnt + 1;
                scl_high_cnt <= 0;
            end

            if (scl && sda_q && !sda) begin
                in_transfer <= 1;
                bit_cnt <= 0;
                byte_cnt <= 0;
            end else if (scl && !sda_q && sda) begin
                in_transfer <= 0;
                bit_cnt <= 0;
            end else if (in_transfer && scl && !scl_q) begin
                if (bit_cnt == 8) begin
                    bit_cnt <= 0;
                    byte_cnt <= byte_cnt + 1;
                end else begin
                    bit_cnt <= bit_cnt + 1;
                end
            end
        end
    end

    property p_bus_known;
        @(posedge clk) disable iff (!nrst)
            !$isunknown({scl, sda});
    endproperty

    property p_start_only_when_idle;
        @(posedge clk) disable iff (!nrst)
            start_seen |-> !start_in_transfer;
    endproperty

    property p_stop_only_when_active;
        @(posedge clk) disable iff (!nrst)
            stop_seen |-> stop_in_transfer;
    endproperty

    property p_sda_stable_while_scl_high;
        @(posedge clk) disable iff (!nrst)
            !sda_high_change_seen;
    endproperty

    property p_scl_low_min;
        @(posedge clk) disable iff (!nrst)
            scl_rise_seen && start_in_transfer |-> (low_count_at_rise >= LOW_MIN_CHECK);
    endproperty

    property p_scl_high_min;
        @(posedge clk) disable iff (!nrst)
            scl_fall_seen && start_in_transfer |-> (high_count_at_fall >= HIGH_MIN_CHECK);
    endproperty

    property p_ack_is_known;
        @(posedge clk) disable iff (!nrst)
            byte_complete_seen |-> ack_known_seen;
    endproperty

    a_bus_known: assert property (p_bus_known)
        else $fatal(1, "I2C protocol violation: SCL/SDA has X/Z at time %0t", $time);

    a_start_only_when_idle: assert property (p_start_only_when_idle)
        else $fatal(1, "I2C protocol violation: repeated START is not supported by this DUT at time %0t", $time);

    a_stop_only_when_active: assert property (p_stop_only_when_active)
        else $fatal(1, "I2C protocol violation: STOP while bus monitor is idle at time %0t", $time);

    a_sda_stable_while_scl_high: assert property (p_sda_stable_while_scl_high)
        else $fatal(1, "I2C protocol violation: SDA changed while SCL was high outside STOP at time %0t", $time);

    a_scl_low_min: assert property (p_scl_low_min)
        else $fatal(1, "I2C protocol violation: SCL low period below Standard-mode minimum at time %0t", $time);

    a_scl_high_min: assert property (p_scl_high_min)
        else $fatal(1, "I2C protocol violation: SCL high period below Standard-mode minimum at time %0t", $time);

    a_ack_is_known: assert property (p_ack_is_known)
        else $fatal(1, "I2C protocol violation: ACK/NACK bit is unknown at time %0t", $time);

endmodule
