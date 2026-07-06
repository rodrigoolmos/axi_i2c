// MODES
// Standard-mode (100 kHz)
// 7 bit addressing
// START / Repeated START


module i2c_physical #(
    parameter unsigned CLOCK_FREQ_HZ = 100_000_000 // System clock frequency
) (
    input  logic        clk,
    input  logic        nrst,

    // Control signals
    input  logic        ena,
    output logic        new_byte,       // Indicates a new byte is ready to be transmitted or received
    output logic        system_idle,    // Indicates the system is idle
    input  logic [7:0]  addr_rw,        // Address/Read-Write control (7-bit address + R/W bit) read 1, write 0
    input  logic [7:0]  data_in,        // Data to be transmitted
    output logic [7:0]  data_out,       // Received data
    output logic        error_ack,      // Indicates an error acknowledgment

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

    parameter unsigned CNT_THD_STA_100K = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000; // 4.0 us  (tHD;STA)
    parameter unsigned CNT_TSU_STA_100K = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us  (tSU;STA)
    parameter unsigned CNT_TSU_STO_100K = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000; // 4.0 us  (tSU;STO)
    parameter unsigned CNT_TBUF_100K    = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us  (tBUF)
    parameter unsigned CNT_THD_TSU_STA_100K = CNT_THD_STA_100K + CNT_TSU_STA_100K; // 8.7 us
    parameter unsigned CNT_THD_TSU_TBUF_100K = CNT_TSU_STO_100K + CNT_TBUF_100K; // 8.7 us
    
    parameter unsigned CNT_W = $clog2(CNT_MAX_100K + 1);

    typedef enum logic [3:0] {
        IDLE,
        START,
        ADDR,
        R_W,
        ADDR_ACK,
        DATA,
        WRITE_ACK,
        READ_ACK,
        RESTART,
        STOP
    } i2c_status_t;
    i2c_status_t i2c_status;

    logic i2c_scl_reg;
    logic i2c_sda_reg;

    logic send_nreceive;

    logic [CNT_W-1:0] i2c_cnt;
    logic i2c_cnt_reset;
    logic i2c_bit_done;

    assign i2c_bit_done = (i2c_cnt == CNT_MAX_100K);

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_cnt <= 0;
        end else if (i2c_cnt_reset) begin
            i2c_cnt <= 0;
        end else begin
            i2c_cnt <= i2c_cnt + 1;
        end
    end

    logic [3:0] data_cnt;
    logic data_cnt_reset;

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            data_cnt <= 0;
        end else if (data_cnt_reset) begin
            data_cnt <= 0;
        end else if (i2c_bit_done) begin
            data_cnt <= data_cnt + 1;
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            data_out <= 0;
        end else begin
            if (send_nreceive && i2c_status == DATA && i2c_cnt == CNT_LOW_100K) begin
                data_out <= data_out << 1 | i2c_sda;
            end
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_status <= IDLE;
            i2c_cnt_reset <= 1;
            data_cnt_reset <= 1;
            send_nreceive <= 0;
            new_byte <= 0;
            system_idle <= 1;
            error_ack <= 0;
        end else begin
            new_byte <= 0;
            case (i2c_status)
                IDLE: begin
                    system_idle <= 1;
                    error_ack <= 0;
                    i2c_cnt_reset <= 1;
                    data_cnt_reset <= 1;
                    if (ena) begin
                        system_idle <= 0;
                        i2c_status <= START;
                    end
                end
                START: begin
                    i2c_cnt_reset <= 0;
                    data_cnt_reset <= 1;
                    if(i2c_cnt == CNT_THD_TSU_STA_100K) begin
                        i2c_status <= ADDR;
                        i2c_cnt_reset <= 1;
                    end
                end
                ADDR: begin
                    data_cnt_reset <= 0;
                    i2c_cnt_reset <= 0;
                    if(i2c_bit_done && data_cnt == 6) begin
                        i2c_status <= R_W;
                        data_cnt_reset <= 1;
                        i2c_cnt_reset <= 1;
                    end
                end
                R_W: begin
                    data_cnt_reset <= 1;
                    i2c_cnt_reset <= 0;
                    if(i2c_bit_done) begin
                        i2c_status <= ADDR_ACK;
                        i2c_cnt_reset <= 1;
                        send_nreceive <= addr_rw[0]; // 1 for read, 0 for write
                    end
                end
                ADDR_ACK: begin
                    i2c_cnt_reset <= 0;
                    data_cnt_reset <= 1;
                    if(i2c_bit_done) begin
                        if (i2c_sda) begin
                            error_ack <= i2c_sda;
                            i2c_status <= STOP;
                        end else if (!ena) begin
                            error_ack <= 0;
                            i2c_status <= STOP;
                        end else begin
                            error_ack <= 0;
                            i2c_status <= DATA;
                        end
                        i2c_cnt_reset <= 1;
                    end
                end
                DATA: begin
                    data_cnt_reset <= 0;
                    i2c_cnt_reset <= 0;
                    if(i2c_bit_done && data_cnt == 7) begin
                        i2c_status <= send_nreceive ? READ_ACK : WRITE_ACK;
                        data_cnt_reset <= 1;
                        i2c_cnt_reset <= 1;
                        new_byte <= 1;
                    end
                end
                WRITE_ACK: begin
                    i2c_cnt_reset <= 0;
                    data_cnt_reset <= 1;
                    if(i2c_bit_done) begin
                        if (i2c_sda) begin
                            error_ack <= i2c_sda;
                            i2c_status <= STOP;
                        end else if (!ena) begin
                            error_ack <= 0;
                            i2c_status <= STOP;
                        end else begin
                            error_ack <= 0;
                            i2c_status <= DATA;
                        end
                        i2c_cnt_reset <= 1;
                    end
                end
                READ_ACK: begin
                    i2c_cnt_reset <= 0;
                    data_cnt_reset <= 1;
                    if(i2c_bit_done) begin
                        i2c_status <= ena ? DATA : STOP;
                        i2c_cnt_reset <= 1;
                    end
                end
                RESTART: begin
                    i2c_cnt_reset <= 0;
                    if(i2c_cnt == CNT_THD_TSU_STA_100K) begin
                        i2c_status <= ADDR;
                        i2c_cnt_reset <= 1;
                    end
                end
                STOP: begin
                    i2c_cnt_reset <= 0;
                    if(i2c_cnt == CNT_THD_TSU_TBUF_100K) begin
                        i2c_status <= IDLE;
                        i2c_cnt_reset <= 1;
                    end
                end
            endcase
        end
    end

    always_comb begin
        case (i2c_status)
            IDLE: begin
                i2c_scl_reg <= 1;
                i2c_sda_reg <= 1;
            end
            START: begin
                if (i2c_cnt < CNT_TSU_STA_100K) begin
                    i2c_scl_reg <= 1;
                    i2c_sda_reg <= 1;
                end else begin
                    i2c_scl_reg <= 1;
                    i2c_sda_reg <= 0;
                end
            end
            ADDR: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg <= 0;
                end else begin
                    i2c_scl_reg <= 1;
                end
                i2c_sda_reg <= addr_rw[7-data_cnt]; // Send address bits MSB first
            end
            R_W: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg <= 0;
                end else begin
                    i2c_scl_reg <= 1;
                end
                i2c_sda_reg <= addr_rw[0];
            end
            ADDR_ACK,
            WRITE_ACK: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg <= 0;
                end else begin
                    i2c_scl_reg <= 1;
                end
                i2c_sda_reg <= 1;
            end
            READ_ACK: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg <= 0;
                end else begin
                    i2c_scl_reg <= 1;
                end
                i2c_sda_reg <= ena ? 0 : 1;
            end
            DATA: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg <= 0;
                end else begin
                    i2c_scl_reg <= 1;
                end
                // If reading, release SDA line (high-impedance)
                i2c_sda_reg <= send_nreceive ? 1 : data_in[7-data_cnt]; // Send address bits MSB first
            end
            RESTART: begin
                if (i2c_cnt < CNT_TSU_STA_100K) begin
                    i2c_scl_reg <= 1;
                    i2c_sda_reg <= 1;
                end else begin
                    i2c_scl_reg <= 1;
                    i2c_sda_reg <= 0;
                end
            end
            STOP: begin
                if (i2c_cnt < CNT_TSU_STO_100K) begin
                    i2c_scl_reg <= 1;
                    i2c_sda_reg <= 0;
                end else begin
                    i2c_scl_reg <= 1;
                    i2c_sda_reg <= 1;
                end
            end                
            default: begin
                i2c_scl_reg <= 1;
                i2c_sda_reg <= 1;
            end
        endcase
    end


    // Pull-up resistors are required on the SCL and SDA lines for proper operation.
    assign i2c_scl = i2c_scl_reg ? 1'bz : 0; // Open-drain output
    assign i2c_sda = i2c_sda_reg ? 1'bz : 0; // Open-drain output

endmodule
