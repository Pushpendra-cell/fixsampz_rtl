`include "falconsoar_pkg.sv"


module samplerz
    import falconsoar_pkg::*;
#(
    parameter int M_MU = 21              // m F_MU = 63 - M_MU
)(
    input                  clk              ,
    input                  rst_n            ,
    exec_operator_if.slave task_itf         ,
    mem_inst_if.master_rd  mem_rd           ,
    mem_inst_if.master_wr  mem_wr
);
    localparam int F_MU = 63 - M_MU;     

    localparam bit [3:0] SAMPLERZ_INITI = 4'd0;
    localparam bit [3:0] SAMPLERZ_512   = 4'd1;
    localparam bit [3:0] SAMPLERZ_1024  = 4'd2;

    wire [3:0]  task_type  = task_itf.input_task[14:11];
    wire        restart    = task_itf.input_task[15   ];
    wire [MEM_ADDR_BITS - 1:0] dst_addr  = task_itf.input_task[TASK_REDUCE_BW - 2*MEM_ADDR_BITS - 1:TASK_REDUCE_BW - 3*MEM_ADDR_BITS];
    wire [MEM_ADDR_BITS - 1:0] src1_addr = task_itf.input_task[TASK_REDUCE_BW - 1*MEM_ADDR_BITS - 1:TASK_REDUCE_BW - 2*MEM_ADDR_BITS];
    wire [MEM_ADDR_BITS - 1:0] src0_addr = task_itf.input_task[TASK_REDUCE_BW - 0*MEM_ADDR_BITS - 1:TASK_REDUCE_BW - 1*MEM_ADDR_BITS];

    wire start = ((task_type == SAMPLERZ_512)   |
                  (task_type == SAMPLERZ_1024)  ) & task_itf.start;

    logic samp_again          ;
    logic done_refill_control ;
    logic done_pre_samp       ;
    logic done_samp_loop      ;
    logic done_berexp         ;
    logic done_chacha20       ;

    logic cnt ;  
    always_ff @(posedge clk) if(start) cnt <= 1'b0; else if(done_berexp) cnt <= ~cnt;

    logic sample_init ;
    always_ff @(posedge clk) begin
        if(~rst_n)                   sample_init <= 'd1 ;
        else if(start && restart)    sample_init <= 'd1 ;
        else if(done_refill_control) sample_init <= 'd0 ;
    end

    wire fetch_en;
    wire start_chacha20       = ((start & restart));
    wire start_refill_control = (sample_init & done_chacha20);
    wire start_pre_samp       = (start & (~sample_init) & ((task_type == SAMPLERZ_512) | (task_type == SAMPLERZ_1024))) | (done_refill_control & sample_init);
    wire start_samp_loop      = done_pre_samp | samp_again | (done_berexp & ~cnt);
    wire start_berexp         = done_samp_loop;
    wire done_samplerz        = (done_berexp & cnt) ;

    assign task_itf.op_done = done_samplerz;

    wire [MEM_ADDR_BITS - 1:0] isigma_addr = src1_addr;   
    wire [MEM_ADDR_BITS - 1:0] mu_addr     = src0_addr;
    wire [MEM_ADDR_BITS - 1:0] random_addr = 12'd130;


//nets
    wire        read_1byte      ;
    wire [79:0] dout_10         ;
    wire [ 7:0] dout_1          ;
    wire        part_en         ;
    wire        read_10byte = start_samp_loop ;

    wire        r_en_pre_samp   ;
    wire [MEM_ADDR_BITS - 1:0] r_addr_pre_samp ;

  
    wire [63:0] fxp_dss        ;   // Q0.63,
    wire [63:0] fxp_ccs        ;   // Q0.63
    wire [63:0] fxp_r          ;   // Q0.63, muxed
    wire [31:0] int_mu_floor   ;
    wire [63:0] fxp_r_l        ;
    wire [31:0] int_mu_floor_l ;
    wire [63:0] fxp_r_r        ;
    wire [31:0] int_mu_floor_r ;
    wire [63:0] fxp_x          ;   // Q7.56
    wire [31:0] int_z          ;
    wire [31:0] int_sample_value ;
    reg  [63:0] sample_value   ;   // Q21.42,
    wire [63:0] fxp_sample_value ; // Q21.42

    wire                       mem_rd_chacha20_en   ;
    wire [MEM_ADDR_BITS - 1:0] mem_rd_chacha20_addr ;
    wire [   BANK_WIDTH - 1:0] mem_rd_chacha20_data ;
    wire [511:0] prng_data;

    always_ff @(posedge clk) if((done_berexp) & (cnt == 0)) sample_value <= fxp_sample_value;

    assign int_sample_value = int_mu_floor + int_z;

   
    assign fxp_sample_value = 64'($signed(int_sample_value)) <<< F_MU;

    assign fxp_r        = cnt ? fxp_r_r        : fxp_r_l;
    assign int_mu_floor = cnt ? int_mu_floor_r : int_mu_floor_l;

    assign mem_rd.en   = sample_init & (~start_pre_samp) ? mem_rd_chacha20_en   : r_en_pre_samp;
    assign mem_rd.addr = sample_init & (~start_pre_samp) ? mem_rd_chacha20_addr : r_addr_pre_samp;
    assign mem_rd_chacha20_data = mem_rd.data;

    assign mem_wr.en   = (done_samplerz & cnt);
    assign mem_wr.addr = dst_addr ;
    assign mem_wr.data = {128'h0, fxp_sample_value, sample_value};


//instance
  
    refill_control i_refill_control
    (
        .clk         ( clk                  ),
        .rst_n       ( rst_n                ),
        .start       ( start_refill_control ),
        .init        ( sample_init          ),
        .fetch_en    ( fetch_en             ),
        .r_data      ( prng_data            ),
        .read_10byte ( read_10byte          ),
        .read_1byte  ( read_1byte           ),
        .dout_10     ( dout_10              ),
        .dout_1      ( dout_1               ),
        .part_en     ( part_en              ),
        .done        ( done_refill_control  )
    );

    chacha20 i_chacha20
    (
        .clk                  ( clk                  ),
        .rst_n                ( rst_n                ),
        .start                ( start_chacha20       ),
        .restart              ( restart              ),
        .sample_init          ( sample_init          ),
        .fetch_en             ( fetch_en             ),
        .done                 ( done_chacha20        ),
        .src_addr             ( random_addr          ),
        .mem_rd_chacha20_en   ( mem_rd_chacha20_en   ),
        .mem_rd_chacha20_addr ( mem_rd_chacha20_addr ),
        .mem_rd_chacha20_data ( mem_rd_chacha20_data ),
        .data_o               ( prng_data            )
    );

 
    pre_samp #(.M_MU(M_MU)) i_pre_samp
    (
        .clk            ( clk             ),
        .rst_n          ( rst_n           ),
        .start          ( start_pre_samp  ),
        .task_type      ( task_type       ),   
        .r_en           ( r_en_pre_samp   ),
        .r_addr         ( r_addr_pre_samp ),
        .r_data         ( mem_rd.data     ),
        .mu_addr        ( mu_addr         ),
        .isigma_addr    ( isigma_addr     ),
        .fxp_dss        ( fxp_dss         ),   
        .fxp_ccs        ( fxp_ccs         ),
        .fxp_r_l        ( fxp_r_l         ),
        .int_mu_floor_l ( int_mu_floor_l  ),
        .fxp_r_r        ( fxp_r_r         ),
        .int_mu_floor_r ( int_mu_floor_r  ),
        .done           ( done_pre_samp   )
    );

    samp_loop i_samp_loop
    (
        .clk          ( clk            ),
        .rst_n        ( rst_n          ),
        .start        ( start_samp_loop),
        .en           ( part_en        ),
        .fxp_dss      ( fxp_dss        ),   
        .fxp_r        ( fxp_r          ),
        .random_bytes ( dout_10        ),
        .fxp_x        ( fxp_x          ),
        .int_z        ( int_z          ),
        .done         ( done_samp_loop ),
      .x_underflow  (                ),   
        .x_uf_gross   (                )
    );

    berexp i_berexp
    (
        .clk          ( clk            ),
        .rst_n        ( rst_n          ),
        .start        ( start_berexp   ),
        .en           ( part_en        ),
        .fxp_x        ( fxp_x          ),
        .fxp_ccs      ( fxp_ccs        ),
        .random_req   ( read_1byte     ),
        .random_bytes ( dout_1         ),
        .samp_again   ( samp_again     ),
        .done         ( done_berexp    )
    );

endmodule
