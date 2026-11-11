module pre_samp
    import sample_pkg::*;
    import falconsoar_pkg::*;
#(

    parameter int M_MU = 21
)(
    input                                clk            ,
    input                                rst_n          ,
    input                                start          ,
    input        [  3:0]                 task_type      ,
    output                               r_en           ,
    output logic [MEM_ADDR_BITS - 1:0]   r_addr         ,
    input        [255:0]                 r_data         ,
    input        [MEM_ADDR_BITS - 1:0]   mu_addr        ,
    input        [MEM_ADDR_BITS - 1:0]   isigma_addr    , 
    output logic [ 63:0]                 fxp_dss        , 
    output logic [ 63:0]                 fxp_ccs        , 
    output logic [ 63:0]                 fxp_r_l        , 
    output logic [ 31:0]                 int_mu_floor_l , 
    output logic [ 63:0]                 fxp_r_r        , 
    output logic [ 31:0]                 int_mu_floor_r , 
    output                               done
);

    localparam int F_MU = 63 - M_MU;      

    localparam logic [3:0] CNT_MU_RDY   = 4'(SAMPLERZ_READ_DELAY    );
    localparam logic [3:0] CNT_LEAF_RDY = 4'(SAMPLERZ_READ_DELAY + 1);
    localparam logic [3:0] CNT_LAST     = 4'(SAMPLERZ_READ_DELAY + 2);

    logic       leaf_index ;              
    logic [3:0] cnt        ;

 
    always_ff @(posedge clk, negedge rst_n) begin
        if      (!rst_n)                          cnt <= 0          ;
        else if ((cnt == 0) && start)             cnt <= 1          ;
        else if (cnt == 0)                        cnt <= 0          ;
        else if (cnt == CNT_LAST)                 cnt <= 0          ;
        else                                      cnt <= cnt + 1'b1 ;
    end

    assign done = (cnt == CNT_LAST);

    assign r_en = ((cnt == 'd0) & start) | (cnt == 'd1);

    always_comb begin
        r_addr = '0;   
        case (cnt)
            'd0: r_addr = mu_addr;
            'd1: r_addr = isigma_addr;
        endcase
    end

    always_ff @(posedge clk, negedge rst_n) begin
        if      (!rst_n)                           leaf_index <= 1'b0;
        else if (cnt == CNT_LEAF_RDY) leaf_index <= leaf_index + 1'b1;
    end

   
    function automatic logic [63:0] frac_of (input logic [63:0] mu_word);
        frac_of = {1'b0, mu_word[F_MU-1:0], {M_MU{1'b0}}};
    endfunction

    function automatic logic [31:0] floor_of (input logic [63:0] mu_word);
        floor_of = {{(32-(64-F_MU)){mu_word[63]}}, mu_word[63:F_MU]};
    endfunction

 
    always_ff @(posedge clk) begin
        if (cnt == CNT_MU_RDY) begin
            fxp_r_l        <= frac_of (r_data[ 0 +: 64]);
            int_mu_floor_l <= floor_of(r_data[ 0 +: 64]);
            fxp_r_r        <= frac_of (r_data[64 +: 64]);
            int_mu_floor_r <= floor_of(r_data[64 +: 64]);
        end
    end

    
    always_ff @(posedge clk) begin
        if (cnt == CNT_LEAF_RDY)
            {fxp_dss, fxp_ccs} <= r_data[128*leaf_index +: 128];
    end
   endmodule
