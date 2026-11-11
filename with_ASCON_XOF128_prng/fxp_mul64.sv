`timescale 1ns/1ps

module fxp_mul64 #(
    parameter int LAT = 3         
)(
    input  logic          clk,
    input  logic [ 63:0]  a,
    input  logic [ 63:0]  b,
    output logic [127:0]  p          
);
    localparam int NA = 3, NB = 4;  
    localparam int WA = 24;         
    localparam int WB = 17;          
    localparam int WP = WA + WB;     
    localparam int WR = WP + 1;      
    localparam int WROW = WR + (NB-1)*WB;   

    // operands
    logic [WA-1:0] a_ch [NA];
    logic [WB-1:0] b_ch [NB];
    always_comb begin
        for (int i = 0; i < NA; i++) a_ch[i] = WA'(a >> (WA*i));  
        for (int j = 0; j < NB; j++) b_ch[j] = WB'(b >> (WB*j));  
    end

   
    (* use_dsp = "yes" *) logic [WP-1:0] pp_c [NA][NB];
    logic [WP-1:0] pp [NA][NB];
    always_comb
        for (int i = 0; i < NA; i++)
            for (int j = 0; j < NB; j++)
                pp_c[i][j] = a_ch[i] * b_ch[j];       

    generate if (LAT >= 2) begin : g_pp_reg
        always_ff @(posedge clk) pp <= pp_c;                
    end else begin : g_pp_comb
        always_comb pp = pp_c;
    end endgenerate

    
    logic [WROW-1:0] row_c [NA];
    logic [WROW-1:0] row   [NA];
    always_comb
        for (int i = 0; i < NA; i++) begin : g_row_sum
            logic [WR-1:0] r;
            r         = WR'(pp[i][0]);
            row_c[i]  = WROW'(r[WB-1:0]);
            for (int j = 1; j < NB; j++) begin
                r = WR'(pp[i][j]) + (r >> WB);
                if (j < NB-1) row_c[i][WB*j +: WB] = r[WB-1:0];
                else          row_c[i][WB*j +: WR] = r;
            end
        end

    generate if (LAT >= 3) begin : g_row_reg
        always_ff @(posedge clk) row <= row_c;
    end else begin : g_row_comb
        always_comb row = row_c;
    end endgenerate

    
    wire [127:0] sum_c = 128'(row[0])
                       + (128'(row[1]) << WA)
                       + (128'(row[2]) << (2*WA));

    localparam int NOUT = (LAT > 3) ? LAT - 2 : 1;  
    (* shreg_extract = "no" *) logic [127:0] stage [NOUT];
    always_ff @(posedge clk) begin
        stage[0] <= sum_c;
        for (int k = 1; k < NOUT; k++) stage[k] <= stage[k-1];
    end
    assign p = stage[NOUT-1];

endmodule
