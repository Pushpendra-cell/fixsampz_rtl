# fixsampz_rtl

This is the RTL design repository accompanying the following [pre-print](https://eprint.iacr.org/2026/2731): Pushpendra Singh, Akshara K B, Utsav Banerjee and Navin Kashyap, "FixSampZ: A Fixed-Point Hardware-Efficient Discrete Gaussian Sampler for Falcon Signatures," Cryptology ePrint Archive, Paper 2026/2731, November 2026.

Falcon, a NIST-standardized post-quantum signature algorithm, offers compact signatures but relies on hardware-intensive floating-point arithmetic. Building on recent theoretical fixed-point formulations, we present a completely floating-point-free hardware architecture for SamplerZ, Falcon’s primary signing bottleneck. By utilizing zero-cost hardware bit-sliced retagging of fixed-point data, which software avoids due to instruction overheads, we enforce tighter data formats at every stage boundary without area or latency penalties. Furthermore, executing floor functions as trivial two's-complement arithmetic right shifts eliminates the complex floor-prediction and redundant data-paths required by floating-point designs. Implemented on UltraScale+ FPGA, our fixed-point sampler exactly matches all 1,024 official test vectors and requires 38% fewer LUTs, 21% less FFs and 36% less DSPs compared to the floating-point baseline, with 21% fewer cycles at a higher clock frequency. We also demonstrate that substituting the baseline ChaCha20 PRNG with lightweight NIST-standardized Ascon-XOF128 achieves further 2-3x hardware resource savings with zero sampling latency overhead.

Our hardware-efficient fixed-point SamplerZ implementation is an adaptation of the floating-point-based sampler design from [FalconSign](https://github.com/YiOuyang1/FalconSign/tree/main/sampler) provided by authors of the corresponding [TCHES 2025 paper](https://tches.iacr.org/index.php/TCHES/article/view/11927). We have extensively modified the floating-point hardware to follow the Type 2 fixed-point formulation from the [CRYPTO 2026 paper](https://eprint.iacr.org/2026/1531) by Daniel De Almeida Braga, Pierre-Alain Fouque, Bachir Lachguel and Thomas Prest titled "Toward a Secure Fixed-Point Implementation of the Falcon Signature Scheme".

If you find our implementation useful for your research, please consider citing the following:

```
@misc{cryptoeprint:2026/2731,
      author = {Pushpendra Singh and Akshara K B and Utsav Banerjee and Navin Kashyap},
      title = {{FixSampZ}: A Fixed-Point Hardware-Efficient Discrete Gaussian Sampler for Falcon Signatures},
      howpublished = {Cryptology {ePrint} Archive, Paper 2026/2731},
      year = {2026},
      url = {https://eprint.iacr.org/2026/2731}
}
```

For any comments or feedback, you may reach out to the authors at: {pushpendrasi, utsav, nkashyap}@iisc.ac.in
