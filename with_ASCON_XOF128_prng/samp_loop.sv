`timescale 1ns/1ps

module samp_loop
    import sample_pkg::*;
    import falconsoar_pkg::*;
#(
    parameter int MUL_LAT = 3      // fxp_mul64 pipeline depth
)(
    input              clk              ,
    input              rst_n            ,
    input              start            ,
    input              en               , 
    input      [63:0]  fxp_dss          , // Q0.63  1/(2 sigma'^2)   
    input      [63:0]  fxp_r            , // Q0.63  in [0,1)         
    input      [79:0]  random_bytes     , // 10 bytes
    output reg [63:0]  fxp_x            , // Q7.56  in [0,61.662]    
    output reg [31:0]  int_z            , // signed 32 bits, 
    output             done             ,

    output reg         x_underflow      , 
    output reg         x_uf_gross         
);

    localparam int GUARD  = 8;
    localparam int XW     = 73;
   
    localparam int UF_TOL = 1 << 20;


    localparam int CNT_SQ_RDY = 3 + MUL_LAT;
    localparam int CNT_X_RDY  = 4 + 2*MUL_LAT;
    localparam int CNT_LAST   = 5 + 2*MUL_LAT;

    logic [4:0] cnt;


    
    always_ff @(posedge clk, negedge rst_n) begin
        if      (~rst_n)                     cnt <= 0          ;
        else if ((cnt == 0) && start )       cnt <= 1          ;
        else if ((cnt == 0) && en )          cnt <= 0          ;
        else if (cnt == 5'(CNT_LAST))        cnt <= 0          ;
        else if (en == 1 )                   cnt <= cnt + 1'b1 ;
    end

    assign done = (cnt == 5'(CNT_LAST));


    logic [79:0] random_bytes_reg  ;
    logic [ 8:0] cmp_result        ;
    logic [ 4:0] cmp_result_bitsum ;
    logic [31:0] int_z0            ;

    wire [31:0] final_cmp_result_bitsum = int_z0 + cmp_result_bitsum;

    always @(posedge clk) begin
        if ((cnt == 0) && start) random_bytes_reg <= random_bytes ;
    end

    always @(posedge clk) begin
        if      ((cnt == 0) && en && start) int_z0 <=          cmp_result_bitsum ;
        else if ((cnt == 1) && en )         int_z0 <= int_z0 + cmp_result_bitsum ;
    end

   
    always @(posedge clk) begin
        if ((cnt == 1) && en ) int_z <= (random_bytes_reg[72] == 1)
                                      ? (final_cmp_result_bitsum + 1)
                                      : (~(final_cmp_result_bitsum) + 1) ;
    end

    assign cmp_result_bitsum = cmp_result[0] + cmp_result[1] + cmp_result[2]
                             + cmp_result[3] + cmp_result[4] + cmp_result[5]
                             + cmp_result[6] + cmp_result[7] + cmp_result[8] ;

    always_comb foreach(cmp_result[i]) begin
        case(cnt)
        5'd0:   cmp_result[i] = (random_bytes[71:0]     < RCDT[i]  );
        5'd1:   cmp_result[i] = (random_bytes_reg[71:0] < RCDT[i+9]);
        default:cmp_result[i] = 1'b0;
        endcase
    end


    logic signed [63:0] diff_c;
    logic        [63:0] adiff;
    logic        [ 4:0] z0_q;

    always_comb
        diff_c = ($signed({{32{int_z[31]}}, int_z}) <<< 58)
               - $signed({5'b0, fxp_r[63:5]});

    always_ff @(posedge clk) if (en && (cnt == 5'd2)) begin

        adiff <= diff_c[63] ? 64'(-diff_c) : 64'(diff_c);
        z0_q  <= int_z0[4:0];
    end


    logic [63:0]  mul_a, mul_b;
    logic [127:0] mul_p;
    logic [63:0]  sq_q954;

    always_comb begin
        
        if (cnt <= 5'(CNT_SQ_RDY)) begin mul_a = adiff;   mul_b = adiff;   end
        else                       begin mul_a = sq_q954; mul_b = fxp_dss; end
    end

    fxp_mul64 #(.LAT(MUL_LAT)) u_mul (.clk(clk), .a(mul_a), .b(mul_b), .p(mul_p));

 
    always_ff @(posedge clk)
        if (en && (cnt == 5'(CNT_SQ_RDY)))
            sq_q954 <= 64'((mul_p + (128'd1 << 61)) >> 62);


    logic signed [XW-1:0] prod_q764, rom_q764, x_c;


    (* rom_style = "distributed" *) logic [63:0] z0sq_val;
    always_comb z0sq_val = ROM_Z0SQ_DSSMAX[z0_q];

    always_comb begin
        prod_q764 = XW'((mul_p + (128'd1 << 52)) >> 53);
        rom_q764  = $signed({{(XW-64){1'b0}}, z0sq_val}) <<< GUARD;
        x_c       = prod_q764 - rom_q764;
    end

    always_ff @(posedge clk) if (en && (cnt == 5'(CNT_X_RDY))) begin
        x_underflow <= x_c[XW-1];
        x_uf_gross  <= x_c[XW-1] && ((-x_c) > XW'(UF_TOL));
 
        fxp_x       <= x_c[XW-1] ? 64'd0
                     : 64'((x_c + (XW'(1) <<< (GUARD-1))) >>> GUARD);
    end

endmodule
