module fp_mul32_lite (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [31:0] res_o        // camino combinacional; registrar externamente
);

  // Unpack + clasificación
  logic        Sa, Sb, Sres;
  logic [7:0]  Ea, Eb;
  logic [23:0] Ma, Mb;
  logic [47:0] P, Pn;
  logic [23:0] Mres;
  logic        a_is_zero, b_is_zero;
  logic        a_is_special, b_is_special;

  // Exponentes en signed para evitar wrap
  logic signed [10:0] Etmp_s;
  logic signed [10:0] Eres_s;
  logic               force_zero;
  logic               force_sat;

  always_comb begin
    Sa = a_i[31];
    Sb = b_i[31];
    Ea = a_i[30:23];
    Eb = b_i[30:23];
    Sres = Sa ^ Sb;

    // Flush subnormales a cero y detecta especiales
    a_is_zero    = (Ea == 8'd0);
    b_is_zero    = (Eb == 8'd0);
    a_is_special = (Ea == 8'hff);
    b_is_special = (Eb == 8'hff);

    // Solo normales entran al multiplicador
    Ma = a_is_zero ? 24'd0 : {1'b1, a_i[22:0]};
    Mb = b_is_zero ? 24'd0 : {1'b1, b_i[22:0]};

    Etmp_s = 11'sd0;
    Eres_s = 11'sd0;
    P      = 48'd0;
    Pn     = 48'd0;
    Mres   = 24'd0;

    force_zero = 1'b0;
    force_sat  = 1'b0;

    // Casos especiales (no generar NaN/Inf): saturar finito o cero
    if (a_is_special || b_is_special) begin
      if (a_is_zero || b_is_zero) force_zero = 1'b1;  // 0 * X -> 0
      else                        force_sat  = 1'b1;  // inf/nan * finite -> max finito
    end else if (a_is_zero || b_is_zero) begin
      force_zero = 1'b1;
    end else begin
      // Exponente provisional (signed): ambos normales
      Etmp_s = $signed({1'b0, Ea}) + $signed({1'b0, Eb}) - 11'sd127;

      // Producto mantisas (rango [1,4))
      P = Ma * Mb;

      // Normalización: [2,4) -> >>1 y E+1
      if (P[47]) begin
        Pn     = {1'b0, P[47:1]};
        Eres_s = Etmp_s + 11'sd1;
      end else begin
        Pn     = P;
        Eres_s = Etmp_s;
      end

      // Mantisa normalizada: 1.int + 23 frac
      Mres = Pn[46:23];
    end
  end

  // Empaquetado "lite":
  // - force_zero => +0
  // - force_sat  => máximo finito con signo
  // - underflow (E<=0) o mantisa 0 => +0
  // - overflow (E>=255) => máximo finito
  // - normal
  logic [31:0] res_c;
  always_comb begin
    if (force_zero) begin
      res_c = 32'h0000_0000;
    end else if (force_sat) begin
      res_c = {Sres, 8'd254, 23'h7fffff};
    end else if ((Eres_s <= 11'sd0) || (Mres == 24'd0)) begin
      res_c = 32'h0000_0000;
    end else if (Eres_s >= 11'sd255) begin
      res_c = {Sres, 8'd254, 23'h7fffff};
    end else begin
      res_c = {Sres, Eres_s[7:0], Mres[22:0]};
    end
  end

  assign res_o = res_c;
  
endmodule
