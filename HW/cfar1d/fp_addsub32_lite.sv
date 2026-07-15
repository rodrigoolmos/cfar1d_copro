module fp_addsub32_lite (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  logic        sub_i,      // 0: a+b, 1: a-b
  output logic [31:0] res_o       // camino combinacional; registrar externamente
);

  // Camino combinacional robusto:
  // - flush de subnormales a cero
  // - clamping de overflow a máximo finito
  // - evita NaN/Inf espurios
  logic Sa, Sb, Sbe;
  logic [7:0] Ea, Eb, Eae, Ebe, EL, ES;
  logic [23:0] Ma, Mb, ML, MS, MSa, Mres, Mtmp;
  logic swap, same_sign, Sres, Sbig, Ssmall;
  logic [7:0] ediff;
  logic [24:0] sum;
  integer lz;

  logic a_is_zero, b_is_zero;
  logic a_is_special, b_is_special;
  logic force_zero, force_sat;
  logic sat_sign;
  logic signed [10:0] Eres_s;

  always_comb begin
    // Defaults
    Sa = a_i[31];
    Sb = b_i[31];
    Sbe = Sb ^ sub_i;
    Ea = a_i[30:23];
    Eb = b_i[30:23];

    a_is_zero    = (Ea == 8'd0);
    b_is_zero    = (Eb == 8'd0);
    a_is_special = (Ea == 8'hff);
    b_is_special = (Eb == 8'hff);

    // Subnormales -> cero
    Ma = a_is_zero ? 24'd0 : {1'b1, a_i[22:0]};
    Mb = b_is_zero ? 24'd0 : {1'b1, b_i[22:0]};
    Eae = a_is_zero ? 8'd1 : Ea;
    Ebe = b_is_zero ? 8'd1 : Eb;

    swap = (Eae < Ebe) || ((Eae == Ebe) && (Ma < Mb));
    EL   = swap ? Ebe : Eae;
    ES   = swap ? Eae : Ebe;
    ML   = swap ? Mb : Ma;
    MS   = swap ? Ma : Mb;

    Sbig      = swap ? Sbe : Sa;
    Ssmall    = swap ? Sa : Sbe;
    same_sign = (Sbig == Ssmall);
    Sres      = Sbig;

    ediff = EL - ES;
    MSa   = (ediff >= 8'd24) ? 24'd0 : (MS >> ediff);
    sum   = same_sign ? ({1'b0, ML} + {1'b0, MSa}) : ({1'b0, ML} - {1'b0, MSa});

    Mres = 24'd0;
    Eres_s = 11'sd0;
    force_zero = 1'b0;
    force_sat = 1'b0;
    sat_sign = Sres;
    lz = 0;
    Mtmp = 24'd0;

    // Casos especiales: evitar no-finitos
    if (a_is_special || b_is_special) begin
      if (a_is_special && b_is_special) begin
        if (Sa != Sbe) begin
          force_zero = 1'b1;  // +inf + -inf (o equivalente) -> 0 en modo lite
        end else begin
          force_sat = 1'b1;
          sat_sign = Sa;
        end
      end else if (a_is_special) begin
        force_sat = 1'b1;
        sat_sign = Sa;
      end else begin
        force_sat = 1'b1;
        sat_sign = Sbe;
      end
    end else if (same_sign && sum[24]) begin
      // Carry -> desplazar derecha y subir exponente
      Mres = sum[24:1];
      Eres_s = $signed({1'b0, EL}) + 11'sd1;
    end else if (sum[23:0] == 24'd0) begin
      // Cero exacto solo si no hubo carry.
      // Evita colapsar a cero sumas válidas del tipo 1.0 + 1.0 (mantisa 0x1000000).
      force_zero = 1'b1;
      Sres = 1'b0;
    end else if (same_sign) begin
      // Mismo signo sin carry: ya normalizado
      Mres = sum[23:0];
      Eres_s = $signed({1'b0, EL});
    end else begin
      // Distinto signo: normalizar a izquierda
      for (int i = 23; i >= 0; i--) begin
        if (sum[i] == 1'b0) lz++; else break;
      end
      Mtmp = sum[23:0] << lz[7:0];
      Mres = Mtmp;
      Eres_s = $signed({1'b0, EL}) - $signed({3'b0, lz[7:0]});
    end
  end

  // Empaquetado (sin subnormales en salida: flush a cero)
  logic [31:0] res_c;
  always_comb begin
    if (force_zero) begin
      res_c = 32'h0000_0000;
    end else if (force_sat) begin
      res_c = {sat_sign, 8'd254, 23'h7fffff};
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
