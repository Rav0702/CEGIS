# PBE_BV_Track_2018 grammar rules:
terminals = BigInt(3)       # 0x0, 0x1, _arg_1
unary_ops = BigInt(5)       # bvnot, smol, ehad, arba, shesh
binary_ops = BigInt(4)      # bvand, bvor, bvxor, bvadd
ternary_ops = BigInt(1)     # im_cvc

# Recurrence: P(d) = terminals + unary × P(d-1) + binary × P(d-1)² + ternary × P(d-1)³
P = zeros(BigInt, 8)
P[1] = terminals

for d in 2:8
    P[d] = terminals + unary_ops * P[d-1] + binary_ops * P[d-1]^2 + ternary_ops * P[d-1]^3
end

println("Programs at depth ≤ d:")
for d in 1:8
    println("Depth $d: $(P[d])")
end

println("")
println("For depth ≤ 8, you need: $(P[8]) enumerations")
