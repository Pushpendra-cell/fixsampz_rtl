`include "falconsoar_pkg.sv"

module ascon_prng
    import falconsoar_pkg::*;
#(
    parameter int unsigned UNROLL     = 1,  // rounds per clock: 1,2,3,4,6
    parameter int unsigned SEED_WORDS = 7   // 64-bit seed words absorbed
)(
    input                                 clk                  ,
    input                                 rst_n                ,
    input                                 start                ,  
    input                                 restart              ,  
    input                                 sample_init          ,
    input                                 fetch_en             ,
    output                                done                 ,  
    input           [MEM_ADDR_BITS - 1:0] src_addr             ,  
    output                                mem_rd_chacha20_en   ,  
    output          [MEM_ADDR_BITS - 1:0] mem_rd_chacha20_addr ,  
    input           [   BANK_WIDTH - 1:0] mem_rd_chacha20_data ,  
    output          [              511:0] data_o                  
);


    if (UNROLL == 0 || (12 % UNROLL) != 0) begin : g_bad_unroll
        $error("ascon_prng: UNROLL must divide 12 (1, 2, 3, 4, 6 or 12)");
    end
    if (SEED_WORDS < 1 || SEED_WORDS > 7) begin : g_bad_seed
        $error("ascon_prng: SEED_WORDS must be 1..7");
    end
    if (BANK_WIDTH < 256) begin : g_bad_bank
        $error("ascon_prng: BANK_WIDTH must be at least 256");
    end

    localparam logic [3:0] UNR       = 4'(UNROLL);
    localparam logic [3:0] LAST_BASE = 4'(12 - UNROLL);
    localparam logic [7:0] LD_FIRST  = 8'(1 + int'(SAMPLERZ_READ_DELAY));  
    localparam logic [7:0] LD_LAST   = 8'(2 + int'(SAMPLERZ_READ_DELAY));  
    localparam logic [2:0] PAD_IDX   = 3'(SEED_WORDS);

    // State layout
    localparam logic [319:0] INIT_STATE = {
        64'he054_7524_db6f_0bde,   // S4
        64'h0ee0_ea53_416b_58cc,   // S3
        64'he750_8fd7_8008_5631,   // S2
        64'hcc7c_e6c7_5f1e_f969,   // S1
        64'hda82_ce76_8d94_47eb    // S0
    };

    function automatic logic [63:0] rotr(input logic [63:0] x, input int unsigned n);
        rotr = (x >> n) | (x << (64 - n));
    endfunction

    
    function automatic logic [7:0] round_const(input logic [3:0] i);
        round_const = {4'hf - i, i};
    endfunction

    function automatic logic [319:0] ascon_round(input logic [319:0] s, input logic [3:0] rnd);
        logic [63:0] x0, x1, x2, x3, x4;
        logic [63:0] t0, t1, t2, t3, t4;
        x0 = s[63:0]; x1 = s[127:64]; x2 = s[191:128]; x3 = s[255:192]; x4 = s[319:256];
        
        x2 = x2 ^ {56'h0, round_const(rnd)};
       
        x0 = x0 ^ x4;  x4 = x4 ^ x3;  x2 = x2 ^ x1;
        t0 = ~x0 & x1; t1 = ~x1 & x2; t2 = ~x2 & x3; t3 = ~x3 & x4; t4 = ~x4 & x0;
        x0 = x0 ^ t1;  x1 = x1 ^ t2;  x2 = x2 ^ t3;  x3 = x3 ^ t4;  x4 = x4 ^ t0;
        x1 = x1 ^ x0;  x0 = x0 ^ x4;  x3 = x3 ^ x2;  x2 = ~x2;
      
        x0 = x0 ^ rotr(x0, 19) ^ rotr(x0, 28);
        x1 = x1 ^ rotr(x1, 61) ^ rotr(x1, 39);
        x2 = x2 ^ rotr(x2,  1) ^ rotr(x2,  6);
        x3 = x3 ^ rotr(x3, 10) ^ rotr(x3, 17);
        x4 = x4 ^ rotr(x4,  7) ^ rotr(x4, 41);
        ascon_round = {x4, x3, x2, x1, x0};
    endfunction

    logic [4:0] buff_idx;
    logic       restart_req, refill_req;

    assign restart_req = start & restart;
    assign refill_req  = (start & ~restart) | (fetch_en & (buff_idx == 5'd31));

    logic [1:0] rd_pulse;   
    
    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) rd_pulse <= 2'b00;
        else        rd_pulse <= {rd_pulse[0], restart_req};
    end

    assign mem_rd_chacha20_en   = |rd_pulse;
    assign mem_rd_chacha20_addr = src_addr + {{(MEM_ADDR_BITS-1){1'b0}}, rd_pulse[1]};

    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,   
        S_LOAD   = 3'd1,   
        S_ABSORB = 3'd2,   
        S_WRITE  = 3'd3,   
        S_PERM   = 3'd4    
    } st_t;

    st_t                     st_q, st_d, after_q, after_d;
    logic [319:0]            s_q, s_d;
    logic [3:0]              rnd_q, rnd_d;
    logic [2:0]              a_q, a_d;     
    logic [5:0]              w_q, w_d;     
    logic [7:0]              ld_q, ld_d;   
    logic                    done_q, done_d;

    
    logic [511:0] seed_all;
    logic [63:0]  seed_word;

    for (genvar k = 0; k < 8; k++) begin : g_seed
        if (k < SEED_WORDS) begin : g_used
            logic [63:0] word_q;
            always_ff @(posedge clk) begin
                if (st_q == S_LOAD && ld_q == ((k < 4) ? LD_FIRST : LD_LAST))
                    word_q <= mem_rd_chacha20_data[64*(k%4) +: 64];
            end
            assign seed_all[64*k +: 64] = word_q;
        end else begin : g_unused
            assign seed_all[64*k +: 64] = 64'h0;
        end
    end

    assign seed_word = seed_all[64*a_q +: 64];

    logic        step;       
    logic        load_init;  
    logic        wr_en;      
    logic        last_wr;    
    logic [63:0] rate_x;     

    always_comb begin
        step      = 1'b0;
        load_init = 1'b0;
        wr_en     = 1'b0;
        last_wr   = 1'b0;
        rate_x    = 64'h0;
        after_d   = after_q;

        case (st_q)
            S_IDLE: begin
                if (refill_req) begin          
                    step    = 1'b1;
                    after_d = S_WRITE;
                end
            end
            S_LOAD: begin
                if (ld_q == LD_LAST) load_init = 1'b1;
            end
            S_ABSORB: begin
                step = 1'b1;
                if (a_q == PAD_IDX) begin
                    rate_x  = 64'h1;         
                    after_d = S_WRITE;
                end else begin
                    rate_x  = seed_word;
                    after_d = S_ABSORB;
                end
            end
            S_WRITE: begin
                wr_en = ~restart_req;
                if (w_q == 6'd63) begin
                    last_wr = 1'b1;
                end else begin
                    step    = 1'b1;
                    after_d = S_WRITE;
                end
            end
            S_PERM: begin
                step = 1'b1;
            end
            default: ;
        endcase
    end

    logic [319:0]            perm_in, perm_out;
    logic [3:0]              rnd_base;

    assign rnd_base = (st_q == S_PERM) ? rnd_q : 4'd0;
    assign perm_in  = s_q ^ {256'h0, rate_x};

    for (genvar u = 0; u < UNROLL; u++) begin : g_round
        logic [319:0] r_out;
        if (u == 0) begin : g_first
            assign r_out = ascon_round(perm_in, rnd_base);
        end else begin : g_next
            assign r_out = ascon_round(g_round[u-1].r_out, rnd_base + 4'(u));
        end
    end

    assign perm_out = g_round[UNROLL-1].r_out;

    always_comb begin
        st_d   = st_q;
        s_d    = s_q;
        rnd_d  = rnd_q;
        a_d    = a_q;
        w_d    = w_q;
        ld_d   = ld_q;
        done_d = 1'b0;

        if (restart_req) begin
            st_d  = S_LOAD;
            ld_d  = 8'd1;
            a_d   = 3'd0;
            w_d   = 6'd0;
            rnd_d = 4'd0;
        end else begin
            if (st_q == S_LOAD)   ld_d = ld_q + 8'd1;
            if (st_q == S_ABSORB) a_d  = a_q + 3'd1;
            if (wr_en)            w_d  = w_q + 6'd1;   
            if (load_init) begin
                s_d  = INIT_STATE;
                st_d = S_ABSORB;
            end else if (last_wr) begin
                st_d   = S_IDLE;
                done_d = 1'b1;
            end else if (step) begin
                s_d = perm_out;
                if (rnd_base == LAST_BASE) begin
                    st_d  = after_d;
                    rnd_d = 4'd0;
                end else begin
                    st_d  = S_PERM;
                    rnd_d = rnd_base + UNR;
                end
            end
        end
    end

    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n) begin
            st_q    <= S_IDLE;
            after_q <= S_IDLE;
            s_q     <= '0;
            rnd_q   <= 4'd0;
            a_q     <= 3'd0;
            w_q     <= 6'd0;
            ld_q    <= 8'd0;
            done_q  <= 1'b0;
        end else begin
            st_q    <= st_d;
            after_q <= after_d;
            s_q     <= s_d;
            rnd_q   <= rnd_d;
            a_q     <= a_d;
            w_q     <= w_d;
            ld_q    <= ld_d;
            done_q  <= done_d;
        end
    end

    assign done = done_q;


    for (genvar l = 0; l < 8; l++) begin : g_lane
        (* ram_style = "distributed" *) logic [63:0] lane_mem [8];

        always_ff @(posedge clk) begin
            if (wr_en && w_q[2:0] == 3'(l)) lane_mem[w_q[5:3]] <= s_q[63:0];
        end

        assign data_o[64*l +: 64] = lane_mem[buff_idx[4:2]];
    end


    always_ff @(posedge clk, negedge rst_n) begin
        if (!rst_n)                        buff_idx <= 5'd0;
        else if (start & restart)          buff_idx <= 5'd0;
        else if (fetch_en & sample_init)   buff_idx <= buff_idx + 5'd2;
        else if (fetch_en & (~sample_init)) buff_idx <= buff_idx + 5'd1;
    end

endmodule
