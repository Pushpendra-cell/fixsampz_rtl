`timescale 1ns/1ps
module berexp
    import sample_pkg::*;
    import falconsoar_pkg::*;
(
    input             clk           ,
    input             rst_n         ,
    input             start         ,
    input             en            ,
    input      [63:0] fxp_x         , // Q7.56, in [0, 61.662]
    input      [63:0] fxp_ccs       , // Q0.63, in (0,1]
    output logic      random_req    ,
    input      [ 7:0] random_bytes  ,
    output logic      samp_again    ,
    output logic      done
);

    localparam int CNT_MUL_RDY   = 3;    
    localparam int CNT_RBE       = 4;    
    localparam int CNT_HORN_BEG  = 5;
    localparam int CNT_HORN_END  = 28;   
    localparam int CNT_YFINAL    = 29;   
    localparam int CNT_SHIFT     = 30;  
    localparam int CNT_REQ0      = 31;   
    localparam int CNT_CMP0      = 32;   
    localparam int CNT_CMP7      = 39;  

    logic [5:0] cnt;

    always_ff @(posedge clk, negedge rst_n) begin
        if     (~rst_n)                     cnt <= '0;
        else if((cnt == 0) && start && en ) cnt <= 6'd1;
        else if((cnt == 0) && en )          cnt <= 6'd0;
        else if((done == 1) && en)          cnt <= 6'd0;
        else if((samp_again == 1) && en)    cnt <= 6'd0;
        else if(en)                         cnt <= cnt + 1'b1;
    end

    logic [63:0]  x_q;          // Q7.56, latched
    logic [63:0]  ccs_q;        // Q0.63, latched
    logic [127:0] s_prod;
    logic [6:0]   s_unc;        // uncapped, 0..88
    logic [5:0]   s_cap;        
    logic [63:0]  rbe_q756;
    logic [63:0]  int_z;        

    always_ff @(posedge clk) if (en && (cnt == 0) && start) begin
        x_q   <= fxp_x;
        ccs_q <= fxp_ccs;
    end

   
    fxp_mul64 #(.LAT(3)) u_mul_s (.clk(clk), .a(x_q), .b(INV_LN2_Q162), .p(s_prod));

    always_ff @(posedge clk) if (en && (cnt == 6'(CNT_MUL_RDY))) begin
        s_unc <= s_prod[124:118];                       // integer part, <= 88
        s_cap <= (s_prod[124:118] > 7'd63) ? 6'd63 : s_prod[124:118];
    end


    (* rom_style = "distributed" *) logic [63:0] s_ln2_val;
    always_comb s_ln2_val = ROM_S_LN2[s_unc];

    always_ff @(posedge clk) if (en && (cnt == 6'(CNT_RBE))) begin


        rbe_q756 <= x_q - s_ln2_val;
        int_z    <= (x_q - s_ln2_val) << 7;
    end


    logic [127:0] products1;
    logic [63:0]  int_y;
    logic [63:0]  int_y_final;
    logic [127:0] products_y_ccs;


    fxp_mul64 #(.LAT(3)) u_mul_h (.clk(clk), .a(int_z), .b(int_y), .p(products1));

    wire       in_horner   = (cnt >= 6'(CNT_HORN_BEG)) && (cnt <= 6'(CNT_HORN_END));
    wire       horn_phase  = (cnt - 6'(CNT_HORN_BEG)) & 6'd1;   
    wire [3:0] horn_idx    = 4'(((cnt - 6'(CNT_HORN_BEG)) >> 1) + 6'd1); 


    (* rom_style = "distributed" *) logic [63:0] c_val;
    always_comb c_val = C_TABLE[horn_idx];

    always_ff @(posedge clk) if (en) begin
        if      (cnt == 6'(CNT_RBE))          int_y <= C_TABLE[0];
        else if (in_horner && horn_phase)     int_y <= c_val - products1[126:63];
    end


    fxp_mul64 #(.LAT(3)) u_mul_c (.clk(clk), .a(int_y), .b(ccs_q), .p(products_y_ccs));
    assign int_y_final = products_y_ccs[126:63];


   

    logic [63:0] z_final;
    always_ff @(posedge clk) if (en && (cnt == 6'(CNT_SHIFT)))
        z_final <= ((int_y_final << 1) - 64'd1) >> s_cap;

    logic [7:0] uniformbits;
    logic       cmp_equl, cmp_bigger, cmp_smaller;
    logic [2:0] byte_idx;

    always_ff @(posedge clk) if (random_req & en) uniformbits <= random_bytes;

    assign random_req = (en & ~(done | samp_again))
                      & ((cnt == 6'(CNT_REQ0))
                         | ((cnt >= 6'(CNT_CMP0)) & (cnt < 6'(CNT_CMP7)) & cmp_equl));

    
    always_comb byte_idx = 3'(6'(CNT_CMP7) - cnt);

    always_comb begin
        cmp_equl    = 1'b0;
        cmp_bigger  = 1'b0;
        cmp_smaller = 1'b0;
        if ((cnt >= 6'(CNT_CMP0)) && (cnt <= 6'(CNT_CMP7))) begin
            cmp_equl    = (uniformbits == z_final[8*byte_idx +: 8]);
            cmp_bigger  = (uniformbits <  z_final[8*byte_idx +: 8]);
            cmp_smaller = (uniformbits >  z_final[8*byte_idx +: 8]);
        end
    end

    always_ff @(posedge clk) begin
        if     (~rst_n)                                            done <= 1'b0;
        else if((done | samp_again) & en )                         done <= 1'b0;
        else if((cnt >= 6'(CNT_CMP0)) & (cnt <= 6'(CNT_CMP7)) & cmp_bigger & en)
                                                                   done <= 1'b1;
        else                                                       done <= 1'b0;
    end

    always_ff @(posedge clk) begin
        if     (~rst_n)                                            samp_again <= 1'b0;
        else if((done | samp_again) & en)                          samp_again <= 1'b0;
        else if((cnt >= 6'(CNT_CMP0)) & (cnt < 6'(CNT_CMP7)) & en & cmp_smaller)
                                                                   samp_again <= 1'b1;
        else if((cnt == 6'(CNT_CMP7)) & en & ~cmp_bigger)          samp_again <= 1'b1;
        else                                                       samp_again <= 1'b0;
    end

endmodule
