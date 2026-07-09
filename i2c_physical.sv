// MODES
// Standard-mode (100 kHz)
// 7 bit addressing


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
    parameter unsigned CNT_PERIOD_100K = CLOCK_FREQ_HZ / 100_000; // 10.0 us
    parameter unsigned CNT_LOW_100K  = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us
    parameter unsigned CNT_HIGH_100K = CNT_PERIOD_100K - CNT_LOW_100K; // 5.3 us
    
    parameter unsigned CNT_THD_STA_100K = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000; // 4.0 us  (tHD;STA)
    parameter unsigned CNT_TSU_STA_100K = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us  (tSU;STA)
    parameter unsigned CNT_TSU_STO_100K = (CLOCK_FREQ_HZ * 64'd40) / 64'd10_000_000; // 4.0 us  (tSU;STO)
    parameter unsigned CNT_TBUF_100K    = (CLOCK_FREQ_HZ * 64'd47) / 64'd10_000_000; // 4.7 us  (tBUF)
    parameter unsigned CNT_THD_TSU_STA_100K = CNT_THD_STA_100K + CNT_TSU_STA_100K; // 8.7 us
    parameter unsigned CNT_THD_TSU_TBUF_100K = CNT_TSU_STO_100K + CNT_TBUF_100K; // 8.7 us

    parameter unsigned CNT_BIT_100K = CNT_LOW_100K + CNT_HIGH_100K;
    parameter unsigned CNT_STOP_100K = CNT_LOW_100K + CNT_TSU_STO_100K + CNT_TBUF_100K;
    parameter unsigned CNT_MAX_100K = (CNT_STOP_100K > CNT_THD_TSU_STA_100K) ? CNT_STOP_100K : CNT_THD_TSU_STA_100K;
    
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
        STOP
    } i2c_status_t;
    i2c_status_t i2c_status;

    logic [3:0] data_cnt;
    logic data_cnt_reset;
    logic data_cnt_inc;

    logic i2c_scl_reg;
    logic i2c_sda_reg;
    logic i2c_scl_ff;
    logic i2c_sda_ff;

    logic posedge_scl;
    logic scl_stretched;

    logic send_nreceive;
    logic read_ack_sda_reg;

    logic [7:0] addr_rw_reg;
    logic [7:0] data_in_reg;

    logic [CNT_W-1:0] i2c_cnt;
    logic i2c_cnt_reset;
    logic i2c_bit_done;
    logic i2c_start_done;
    logic i2c_stop_done;
    logic i2c_cnt_done;
    logic i2c_bit_state;

    assign i2c_bit_done = (i2c_cnt == CNT_BIT_100K);
    assign i2c_start_done = (i2c_cnt == CNT_THD_TSU_STA_100K);
    assign i2c_stop_done = (i2c_cnt == CNT_STOP_100K);
    assign i2c_bit_state = (i2c_status == ADDR)     ||
                           (i2c_status == R_W)      ||
                           (i2c_status == ADDR_ACK) ||
                           (i2c_status == DATA)     ||
                           (i2c_status == WRITE_ACK)||
                           (i2c_status == READ_ACK);
    assign i2c_cnt_done = (i2c_bit_state && i2c_bit_done) ||
                          (i2c_status == START && i2c_start_done) ||
                          (i2c_status == STOP && i2c_stop_done);
    assign scl_stretched = i2c_scl_reg && !i2c_scl;

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_scl_ff <= 1;
        end else begin
            i2c_scl_ff <= i2c_scl;
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_sda_ff <= 1;
        end else begin
            i2c_sda_ff <= i2c_sda;
        end
    end

    assign posedge_scl = !i2c_scl_ff && i2c_scl;

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_cnt <= 0;
        end else if (i2c_cnt_reset || i2c_cnt_done) begin
            i2c_cnt <= 0;
        end else if (scl_stretched) begin
            i2c_cnt <= i2c_cnt;
        end else begin
            i2c_cnt <= i2c_cnt + 1;
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            data_cnt <= 0;
        end else if (data_cnt_reset) begin
            data_cnt <= 0;
        end else if (data_cnt_inc) begin
            data_cnt <= data_cnt + 1;
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            data_cnt_inc <= 0;
        end else if (data_cnt_reset) begin
            data_cnt_inc <= 0;
        end else begin
            data_cnt_inc <= (i2c_bit_done && i2c_status == ADDR && data_cnt < 6) ||
                            (i2c_bit_done && i2c_status == DATA && data_cnt < 7);
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            data_out <= 0;
        end else begin
            if (send_nreceive && i2c_status == DATA && posedge_scl) begin
                data_out <= data_out << 1 | i2c_sda;
            end
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            read_ack_sda_reg <= 1;
        end else if (i2c_status == READ_ACK && i2c_cnt < CNT_LOW_100K) begin
            read_ack_sda_reg <= ena ? 0 : 1;
        end
    end

    always_ff @(posedge clk or negedge nrst) begin
        if (!nrst) begin
            i2c_status <= IDLE;
            i2c_cnt_reset <= 1;
            data_cnt_reset <= 1;
            send_nreceive <= 0;
            addr_rw_reg <= 0;
            data_in_reg <= 0;
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
                        addr_rw_reg <= addr_rw;
                        i2c_status <= START;
                    end
                end
                START: begin
                    i2c_cnt_reset <= 0;
                    data_cnt_reset <= 1;
                    if(i2c_start_done) begin
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
                        send_nreceive <= addr_rw_reg[0]; // 1 for read, 0 for write
                    end
                end
                ADDR_ACK: begin
                    i2c_cnt_reset <= 0;
                    data_cnt_reset <= 1;
                    if (posedge_scl) begin
                        error_ack <= i2c_sda;
                    end
                    if(i2c_bit_done) begin
                        if (error_ack) begin
                            i2c_status <= STOP;
                        end else if (!ena) begin
                            i2c_status <= STOP;
                        end else begin
                            if (!send_nreceive) begin
                                data_in_reg <= data_in;
                            end
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
                    if (posedge_scl) begin
                        error_ack <= i2c_sda;
                    end
                    if(i2c_bit_done) begin
                        if (error_ack) begin
                            i2c_status <= STOP;
                        end else if (!ena) begin
                            i2c_status <= STOP;
                        end else begin
                            if (!send_nreceive) begin
                                data_in_reg <= data_in;
                            end
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
                STOP: begin
                    i2c_cnt_reset <= 0;
                    if(i2c_stop_done) begin
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
                i2c_scl_reg = 1;
                i2c_sda_reg = 1;
            end
            START: begin
                if (i2c_cnt < CNT_TSU_STA_100K) begin
                    i2c_scl_reg = 1;
                    i2c_sda_reg = 1;
                end else begin
                    i2c_scl_reg = 1;
                    i2c_sda_reg = 0;
                end
            end
            ADDR: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg = 0;
                end else begin
                    i2c_scl_reg = 1;
                end
                i2c_sda_reg = addr_rw_reg[7-data_cnt]; // Send address bits MSB first
            end
            R_W: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg = 0;
                end else begin
                    i2c_scl_reg = 1;
                end
                i2c_sda_reg = addr_rw_reg[0];
            end
            ADDR_ACK,
            WRITE_ACK: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg = 0;
                end else begin
                    i2c_scl_reg = 1;
                end
                i2c_sda_reg = 1;
            end
            READ_ACK: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg = 0;
                end else begin
                    i2c_scl_reg = 1;
                end
                i2c_sda_reg = read_ack_sda_reg;
            end
            DATA: begin
                if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg = 0;
                end else begin
                    i2c_scl_reg = 1;
                end
                // If reading, release SDA line (high-impedance)
                i2c_sda_reg = send_nreceive ? 1 : data_in_reg[7-data_cnt]; // Send data bits MSB first
            end
            STOP: begin
                if (i2c_cnt < 1) begin
                    // avoid accidental START condition
                    i2c_scl_reg = 0;
                    i2c_sda_reg = i2c_sda_ff;
                end else if (i2c_cnt < CNT_LOW_100K) begin
                    i2c_scl_reg = 0;
                    i2c_sda_reg = 0;
                end else if (i2c_cnt < CNT_TSU_STO_100K + CNT_LOW_100K) begin
                    i2c_scl_reg = 1;
                    i2c_sda_reg = 0;
                end else begin
                    i2c_sda_reg = 1;
                    i2c_scl_reg = 1;
                end
            end                
            default: begin
                i2c_scl_reg = 1;
                i2c_sda_reg = 1;
            end
        endcase
    end


    // Pull-up resistors are required on the SCL and SDA lines for proper operation.
    assign i2c_scl = i2c_scl_reg ? 1'bz : 0; // Open-drain output
    assign i2c_sda = i2c_sda_reg ? 1'bz : 0; // Open-drain output

endmodule
