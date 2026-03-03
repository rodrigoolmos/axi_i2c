// MODES
// Standard-mode (100 kHz)
// Fast-mode (400 kHz)
// Fast-mode Plus (1 MHz)
// 7 bit addressing
// Clock stretching
// START / Repeated START


module i2c_physical #(
    parameter unsigned CLOCK_FREQ_HZ = 100_000_000 // System clock frequency
) (
    input  logic        clk,
    input  logic        nrst,

    // Control signals
    input  logic        ena,
    output logic        new_byte,       // Indicates a new byte is ready to be transmitted or received
    input  logic [1:0]  i2c_mode,       // Indicates the current mode of operation
    output logic        system_idle,    // Indicates the system is idle
    input  logic [7:0]  addr_rw,        // Address/Read-Write control (7-bit address + R/W bit) read 1, write 0
    input  logic [7:0]  data_in,        // Data to be transmitted
    output logic [7:0]  data_out,       // Received data
    output logic        error_ack,       // Indicates an error acknowledgment

    // i2c signals
    inout logic        i2c_scl,
    inout logic        i2c_sda
);
    // =====================
    // Standard-mode (100 kHz)
    // =====================
    parameter unsigned CNT_LOW_100K  = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us
    parameter unsigned CNT_HIGH_100K = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000; // 4.0 us
    parameter unsigned CNT_MAX_100K = CNT_LOW_100K + CNT_HIGH_100K;       // 8.7 us

    // parameter unsigned CNT_THD_STA_100K = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000; // 4.0 us  (tHD;STA)
    // parameter unsigned CNT_TSU_STA_100K = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us  (tSU;STA)
    // parameter unsigned CNT_TSU_STO_100K = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000; // 4.0 us  (tSU;STO)
    // parameter unsigned CNT_TBUF_100K    = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us  (tBUF)
    
    // =====================
    // Fast-mode (400 kHz)
    // =====================
    parameter unsigned CNT_LOW_400K  = (CLOCK_FREQ_HZ * 64'd13) / 64'd10_000_000; // 1.3 us
    parameter unsigned CNT_HIGH_400K = (CLOCK_FREQ_HZ * 64'd6)  / 64'd10_000_000; // 0.6 us
    parameter unsigned CNT_MAX_400K = CNT_LOW_400K + CNT_HIGH_400K;       // 1.9 us

    // parameter unsigned CNT_THD_STA_400K = (CLOCK_FREQ_HZ * 64'd6)  / 64'd10_000_000; // 0.6 us  (tHD;STA)
    // parameter unsigned CNT_TSU_STA_400K = (CLOCK_FREQ_HZ * 64'd6)  / 64'd10_000_000; // 0.6 us  (tSU;STA)
    // parameter unsigned CNT_TSU_STO_400K = (CLOCK_FREQ_HZ * 64'd6)  / 64'd10_000_000; // 0.6 us  (tSU;STO)
    // parameter unsigned CNT_TBUF_400K    = (CLOCK_FREQ_HZ * 64'd13) / 64'd10_000_000; // 1.3 us  (tBUF)

    // ==========================
    // Fast-mode Plus (1 MHz)
    // ==========================
    parameter unsigned CNT_LOW_1M  = (CLOCK_FREQ_HZ * 64'd5)  / 64'd10_000_000;  // 0.5 us
    parameter unsigned CNT_HIGH_1M = (CLOCK_FREQ_HZ * 64'd26) / 64'd100_000_000; // 0.26 us
    parameter unsigned CNT_MAX_1M = CNT_LOW_1M + CNT_HIGH_1M;            // 0.76 us

    // parameter unsigned CNT_THD_STA_1M = (CLOCK_FREQ_HZ * 64'd26) / 64'd100_000_000; // 0.26 us (tHD;STA)
    // parameter unsigned CNT_TSU_STA_1M = (CLOCK_FREQ_HZ * 64'd26) / 64'd100_000_000; // 0.26 us (tSU;STA)
    // parameter unsigned CNT_TSU_STO_1M = (CLOCK_FREQ_HZ * 64'd26) / 64'd100_000_000; // 0.26 us (tSU;STO)
    // parameter unsigned CNT_TBUF_1M    = (CLOCK_FREQ_HZ * 64'd5)  / 64'd10_000_000;  // 0.5 us  (tBUF)

    localparam int unsigned DIV_W = $clog2(CLOCK_FREQ_HZ/10 + 2);

    logic [DIV_W-1:0] CNT_LOW;
    logic [DIV_W-1:0] CNT_HIGH;
    logic [DIV_W-1:0] CNT_MAX;

    logic [DIV_W-1:0] i2c_timing_cnt;
    logic ena_i2c_clk;
    logic reset_i2c_clk;
    logic end_i2c_clk;
    logic end_low_i2c_clk;
    logic end_high_i2c_clk;

    logic        i2c_scl_reg;
    logic        i2c_sda_reg;
    logic        error_ack_reg;
    logic [7:0]  data_in_reg;
    logic [7:0]  data_out_reg;
    logic [7:0]  addr_rw_reg;

    logic [2:0]  bit_cnt;

    // State machine states
    typedef enum logic [3:0] {
        IDLE,
        START,
        SEND_ADDR_RW,
        ADDR_ACK,
        WRITE_BYTE,
        WRITE_ACK,
        READ_BYTE,
        READ_ACK,
        REPEATED_START,
        STOP
    } state_t;
    state_t i2c_state;


    // Timming selection based on mode
    always_comb begin
        case (i2c_mode)
            2'b00: begin // Standard-mode (100 kHz)
                CNT_LOW = CNT_LOW_100K;
                CNT_HIGH = CNT_HIGH_100K;
                CNT_MAX = CNT_MAX_100K;
            end
            2'b01: begin // Fast-mode (400 kHz)
                CNT_LOW = CNT_LOW_400K;
                CNT_HIGH = CNT_HIGH_400K;
                CNT_MAX = CNT_MAX_400K;
            end
            2'b10: begin // Fast-mode Plus (1 MHz)
                CNT_LOW = CNT_LOW_1M;
                CNT_HIGH = CNT_HIGH_1M;
                CNT_MAX = CNT_MAX_1M;
            end
            default: begin
                CNT_LOW = CNT_LOW_100K;
                CNT_HIGH = CNT_HIGH_100K;
                CNT_MAX = CNT_MAX_100K;
            end
        endcase
    end

    // I2C clock generation logic
    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_timing_cnt <= 0;
        end else begin
            if (reset_i2c_clk) begin
                i2c_timing_cnt <= 0;
            end else if (ena_i2c_clk && i2c_timing_cnt < CNT_MAX) begin
                i2c_timing_cnt <= i2c_timing_cnt + 1;
            end
        end
    end
    assign end_i2c_clk = (i2c_timing_cnt == CNT_MAX);
    assign end_low_i2c_clk = (i2c_timing_cnt == CNT_LOW);
    assign end_high_i2c_clk = (i2c_timing_cnt == CNT_HIGH);

    // FSM i2c
    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_state <= IDLE;
            reset_i2c_clk <= 1;
            i2c_scl_reg <= 1;
            i2c_sda_reg <= 1;
            data_in_reg <= 0;
            addr_rw_reg <= 0;
            bit_cnt <= 7;
            error_ack_reg <= 0;
            system_idle <= 1;
            new_byte <= 0;
            error_ack <= 0;
            data_out <= 0;
        end else begin
            case (i2c_state)
                IDLE: begin
                    system_idle <= 1;
                    new_byte <= 0;
                    reset_i2c_clk <= 1;
                    i2c_scl_reg <= 1;
                    i2c_sda_reg <= 1;
                    error_ack <= error_ack_reg;
                    if (ena) begin
                        system_idle <= 0;
                        error_ack_reg <= 0;
                        addr_rw_reg <= addr_rw;
                        reset_i2c_clk <= 0;
                        i2c_state <= START;
                    end
                end
                START: begin
                    i2c_sda_reg <= 0;
                    i2c_scl_reg <= 1;
                    if (end_high_i2c_clk) begin
                        reset_i2c_clk <= 0;
                        i2c_state <= SEND_ADDR_RW;
                    end
                end
                REPEATED_START: begin
                    new_byte <= 0;
                    // TODO: Implement repeated start condition (SDA goes low while SCL is high)
                end
                SEND_ADDR_RW: begin
                    i2c_sda_reg <= addr_rw_reg[bit_cnt];
                    i2c_scl_reg <= i2c_timing_cnt < CNT_LOW ? 0 : 1;
                    if (end_i2c_clk) begin
                        reset_i2c_clk <= 0;
                        if (bit_cnt == 0) begin
                            i2c_state <= ADDR_ACK;
                        end else begin
                            bit_cnt <= bit_cnt - 1;
                        end
                    end
                end
                ADDR_ACK: begin
                    i2c_sda_reg <= 1;
                    i2c_scl_reg <= i2c_timing_cnt < CNT_LOW ? 0 : 1;
                    if (end_low_i2c_clk) begin
                        data_in_reg <= data_in; // Latch data to be sent
                        if (i2c_sda) begin      // ACK received (SDA low)
                            i2c_state <= addr_rw_reg[7] ? READ_BYTE : WRITE_BYTE;
                        end else begin          // NACK received (SDA high)
                            i2c_state <= IDLE;
                            error_ack_reg <= 1;
                        end
                    end
                end
                WRITE_BYTE: begin
                    new_byte <= 0;
                    i2c_sda_reg <= data_in_reg[bit_cnt];
                    i2c_scl_reg <= i2c_timing_cnt < CNT_LOW ? 0 : 1;
                    if (end_i2c_clk) begin
                        reset_i2c_clk <= 0;
                        if (bit_cnt == 0) begin
                            i2c_state <= WRITE_ACK;
                        end else begin
                            bit_cnt <= bit_cnt - 1;
                        end
                    end
                end
                WRITE_ACK: begin
                    i2c_sda_reg <= 1;
                    i2c_scl_reg <= i2c_timing_cnt < CNT_LOW ? 0 : 1;
                    if (end_low_i2c_clk) begin
                        new_byte <= 1;
                        if (i2c_sda) begin      // ACK received (SDA low)
                            if (ena) begin
                                if (addr_rw == addr_rw_reg) begin
                                    i2c_state <= WRITE_BYTE;
                                    data_in_reg <= data_in; // Latch data to be sent
                                end else begin
                                    i2c_state <= REPEATED_START;
                                end
                            end else begin
                                i2c_state <= STOP;
                            end
                        end else begin          // NACK received (SDA high)
                            i2c_state <= STOP;
                            error_ack_reg <= 1;
                        end
                    end
                end
                READ_BYTE: begin
                    new_byte <= 0;
                    i2c_sda_reg <= 1; // Release SDA for reading
                    i2c_scl_reg <= i2c_timing_cnt < CNT_LOW ? 0 : 1;
                    if (end_low_i2c_clk) begin
                        reset_i2c_clk <= 0;
                        data_out_reg[bit_cnt] <= i2c_sda; // Sample SDA
                        if (bit_cnt == 0) begin
                            i2c_state <= READ_ACK;
                        end else begin
                            bit_cnt <= bit_cnt - 1;
                        end
                    end
                end
                READ_ACK: begin
                    i2c_sda_reg <= !ena; // ACK if more data is expected, otherwise NACK
                    i2c_scl_reg <= i2c_timing_cnt < CNT_LOW ? 0 : 1;
                    if (end_i2c_clk) begin
                        new_byte <= 1;
                        data_out <= data_out_reg; // Output the received byte
                        reset_i2c_clk <= 0;
                        if (ena) begin
                            i2c_state <= addr_rw == addr_rw_reg ? READ_BYTE : REPEATED_START;
                        end else begin
                            i2c_state <= STOP; // No more data, send stop condition
                        end
                    end
                end
                STOP: begin
                    new_byte <= 0;
                    i2c_sda_reg <= 0;
                    i2c_scl_reg <= 1;
                    if (end_high_i2c_clk) begin
                        i2c_sda_reg <= 1;
                        reset_i2c_clk <= 0;
                        i2c_state <= IDLE;
                    end
                end
                default: begin
                    i2c_state <= IDLE;
                end
            endcase
        end
    end
    
    // Clock stretching generation
    always_comb begin
        if (i2c_timing_cnt < CNT_LOW) begin
            ena_i2c_clk = 1;
        end else begin
            if (i2c_scl != 0) begin
                ena_i2c_clk = 0;
            end else begin
                ena_i2c_clk = 1;
            end
        end
    end

    // Output assignments
    assign i2c_scl = i2c_scl_reg ? 1'bz : 0; // Open-drain output
    assign i2c_sda = i2c_sda_reg ? 1'bz : 0; // Open-drain output

endmodule
