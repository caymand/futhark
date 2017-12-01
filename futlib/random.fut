-- | Random number generation inspired by <random> in C++.
--
-- Example usage:
--
-- module dist = uniform_real_distribution f32 minstd_rand
-- let rng = minstd_rand.rng_from_seed [123]
-- let (rng, x) = dist.rand (1,6)

import "/futlib/math"
import "/futlib/array"

-- Quick and dirty hashing to mix in something that looks like entropy.
-- From http://stackoverflow.com/a/12996028
local
let hash(x: i32): i32 =
  let x = ((x >>> 16) ^ x) * 0x45d9f3b
  let x = ((x >>> 16) ^ x) * 0x45d9f3b
  let x = ((x >>> 16) ^ x) in
  x

-- | Low-level modules that act as sources of random numbers in some
-- uniform distribution.
module type rng_engine = {
  -- | A module for the type of integers generated by the engine.
  module int: integral
  -- | The state of the engine.
  type rng

  -- | Initialise an RNG state from a seed.  Even if the seed array is
  -- empty, the resulting RNG should still behave reasonably.  It is
  -- permissible for this function to process the seed array
  -- sequentially, so don't make it too large.
  val rng_from_seed: []i32 -> rng

  -- | Split an RNG state into several states.  Implementations of
  -- this function tend to be cryptographically unsound, so be
  -- careful.
  val split_rng: i32 -> rng -> []rng

  -- | Combine several RNG states into a single state - typically done
  -- with the result of 'split_rng'.
  val join_rng: []rng -> rng

  -- | Generate a single random element, and a new RNG state.
  val rand: rng -> (rng,int.t)

  -- | The minimum value potentially returned by the generator.
  val min: int.t

  -- | The maximum value potentially returned by the generator.
  val max: int.t
}

module type rng_distribution = {
  -- | The random number engine underlying this distribution.
  module engine: rng_engine

  -- | A module describing the type of values produced by this random
  -- distribution.
  module num: numeric

  -- | The dynamic configuration of the distribution.
  type distribution

  val rand: distribution -> engine.rng -> (engine.rng, num.t)
}

module linear_congruential_engine (T: integral) (P: {
  val a: T.t
  val c: T.t
  val m: T.t
}): rng_engine with int.t = T.t with rng = T.t = {
  type t = T.t
  type rng = t

  module int = T

  let rand (x: rng): (rng, t) =
    let rng' = (P.a T.* x T.+ P.c) T.%% P.m
    in (rng',rng')

  let rng_from_seed [n] (seed: [n]i32) =
    let seed' =
      loop seed' = T.i32 1 for i < n do
        ((seed' T.>>> T.i32 16) T.^ seed') T.^
        T.i32 (seed[i] ^ 0b1010101010101)
    in (rand seed').1

  let split_rng (n: i32) (x: rng): [n]rng =
    map (\i -> x T.^ T.i32 (hash i)) (iota n)

  let join_rng [n] (xs: [n]rng): rng =
    reduce (T.^) (T.i32 0) xs

  let min = T.i32 0
  let max = P.m
}

-- | A random number engine that uses the "subtract with carry"
-- algorithm.  Presently quite slow.  The size of the state is
-- proportional to the long lag.
module subtract_with_carry_engine (T: integral) (P: {
  -- | Word size: number of bits in each word of the state sequence.
  -- Should be positive and less than the number of bits in T.t.
  val w: i32
  -- | Long lag: distance between operand values.
  val r: i32
  -- | Short lag: number of elements between advances.  Should be
  -- positive and less than 'r'.
  val s: i32
}): rng_engine with int.t = T.t = {
  let long_lag = P.r
  let word_size = P.w
  let short_lag = P.s
  let modulus = T.i32 (1 << word_size)

  -- We use this one for initialisation.
  module e = linear_congruential_engine T {
    let a = T.u32 40014u32
    let c = T.u32 0u32
    let m = T.u32 2147483563u32
  }

  module int = T
  type t = T.t
  type rng = {x: [P.r]T.t,
              carry: bool,
              k: i32}

  let rand ({x, carry, k}: rng): (rng, t) =
    let short_index = k - short_lag
    let short_index = if short_index < 0
                      then short_index + long_lag
                      else short_index
    let (xi, carry) =
      if T.(x[short_index] >= x[k] + bool carry)
      then (T.(x[short_index] - x[k] - bool carry),
            false)
      else (T.(modulus - x[k] - bool carry + x[short_index]),
            true)
    let x = (copy x) with [k] <- xi
    let k = (k + 1) % long_lag
    in ({x, carry, k}, xi)

  let rng_from_seed [n] (seed: [n]i32): rng =
    let rng = e.rng_from_seed seed
    let (x, rng) = loop (x, rng) = (replicate P.r (T.i32 0), rng)
                     for i < P.r do let (v, rng) = e.rand rng
                                    in (x with [i] <- T.(v % modulus),
                                        rng)
    let carry = T.(last x == i32 0)
    let k = 0
    in {x, carry, k}

  let split_rng (n: i32) ({x, carry, k}: rng): [n]rng =
    map (\i -> {x=map (T.^(T.i32 (hash i))) x, carry, k}) (iota n)

  let join_rng [n] (xs: [n]rng): rng =
    xs[0] -- FIXME

  let min = T.i32 0
  let max = T.(modulus - i32 1)
}

-- | An engine adaptor class template that adapts a pseudo-random
-- number generator Engine type by using only r elements of each block
-- of p elements from the sequence it produces, discarding the rest.
--
-- The adaptor keeps and internal counter of how many elements have
-- been produced in the current block.
module discard_block_engine (K: {
  -- | Block size: number of elements in each block.  Must be
  -- positive.
  val p: i32
  -- | Used block: number of elements in the block that are used (not
  -- discarded). The rest (p-r) are discarded. This parameter should
  -- be greater than zero and lower than or equal to p.
  val r: i32}) (E: rng_engine): rng_engine with int.t = E.int.t = {
  type t = E.int.t
  module int = E.int
  type rng = (E.rng, i32)

  let min = E.min
  let max = E.max

  let rng_from_seed (xs: []i32) =
    (E.rng_from_seed xs, 0)

  let split_rng (n: i32) ((rng, i): rng): [n]rng =
    map (\rng' -> (rng', i)) (E.split_rng n rng)

  let join_rng (rngs: []rng): rng =
    let (rngs', is) = unzip rngs
    in (E.join_rng rngs', reduce i32.max 0 is)

  let rand ((rng,i): rng): (rng, t) =
    let (rng, i) =
      if i >= K.r then (loop rng for j < K.r - i do (E.rand rng).1, 0)
                  else (rng, i+1)
    let (rng, x) = E.rand rng
    in ((rng, i), x)
}

-- | An engine adaptor that adapts an 'rng_engine' so that the
-- elements are delivered in a different sequence.
--
-- The RNG keeps a buffer of 'k' generated numbers internally, and
-- when requested, returns a randomly selected number within the
-- buffer, replacing it with a value obtained from its base engine.
module shuffle_order_engine (K: {val k: i32}) (E: rng_engine)
                          : rng_engine with int.t = E.int.t = {
  type t = E.int.t
  module int = E.int
  type rng = (E.rng, [K.k]t)

  let build_table (rng: E.rng) =
    let xs = replicate K.k (int.i32 0)
    in loop (rng,xs) for i < K.k do
         let (rng,x) = E.rand rng
         in (rng, xs with [i] <- x)

  let rng_from_seed (xs: []i32) =
    build_table (E.rng_from_seed xs)

  let split_rng (n: i32) ((rng, _): rng): [n]rng =
    map build_table (E.split_rng n rng)

  let join_rng (rngs: []rng) =
    let (rngs', _) = unzip rngs
    in build_table (E.join_rng rngs')

  let rand ((rng,table): rng): (rng, int.t) =
    let (rng,x) = E.rand rng
    let i = i32.i64 (int.to_i64 x) % K.k
    let (rng,y) = E.rand rng
    in ((rng, (copy table) with [i] <- y), table[i])

  let min = E.min
  let max = E.max
}

-- | The xorshift128+ engine.  Uses two 64-bit words as state.
module xorshift128plus: rng_engine with int.t = u64 = {
  module int = u64
  type rng = (u64,u64)

  -- We currently have a problem where everything that is produced
  -- must be convertible (losslessly) to a i64.  Therefore, we mask
  -- off the highest bit to avoid negative numbers.
  let mask (x: u64) = x & (~(1u64<<63u64))

  let rand ((x,y): rng): (rng, u64) =
    let x = x ^ (x << 23u64)
    let new_x = y
    let new_y = x ^ y ^ (x >> 17u64) ^ (y >> 26u64)
    in ((new_x,new_y), mask (new_y + y))

  let rng_from_seed [n] (seed: [n]i32) =
    loop (a,b) = (1u64,u64.i32 n) for i < n do
      if n % 2 == 0
      then (rand (a^u64.i32 (hash seed[i]),b)).1
      else (rand (a, b^u64.i32 (hash seed[i]))).1

  let split_rng (n: i32) ((x,y): rng): [n]rng =
    map (\i -> let (a,b) = (rand (rng_from_seed [hash (i^n)])).1
               in (rand (x^a,y^b)).1) (iota n)

  let join_rng [n] (xs: [n]rng): rng =
    reduce (\(x1,y1) (x2,y2) -> (x1^x2,y1^y2)) (0u64,0u64) xs

  let min = 0u64
  let max = mask 0xFF_FF_FF_FF_FF_FF_FF_FFu64
}

-- | A 'linear_congruential_engine' producing 'u32' values and
-- initialised with a=48271, c=u and m=2147483647.  This is the same
-- configuration as in C++.
module minstd_rand: rng_engine with int.t = u32 =
  linear_congruential_engine u32 {
    let a = 48271u32
    let c = 0u32
    let m = 2147483647u32
}

-- | A 'linear_congruential_engine' producing 'u32' values and
-- initialised with a=16807, c=u and m=2147483647.  This is the same
-- configuration as in C++.
module minstd_rand0: rng_engine with int.t = u32 =
  linear_congruential_engine u32 {
    let a = 16807u32
    let c = 0u32
    let m = 2147483647u32
}

-- | A subtract-with-carry pseudo-random generator of 24-bit numbers,
-- generally used as the base engine for the ranlux24 generator.  It
-- is an instantiation of subtract_with_carry_engine with w=24, s=10,
-- r=24.
module ranlux24_base: rng_engine with int.t = u32 =
  subtract_with_carry_engine u32 {
    let w = 24
    let s = 10
    let r = 24
  }

-- | A subtract-with-carry pseudo-random generator of 48-bit numbers,
-- generally used as the base engine for the ranlux24 generator.  It
-- is an instantiation of subtract_with_carry_engine with w=48, s=5,
-- r=12.
module ranlux48_base: rng_engine with int.t = u64 =
  subtract_with_carry_engine u64 {
    let w = 48
    let s = 5
    let r = 12
  }

-- | A subtract-with-carry pseudo-random generator of 24-bit numbers
-- with accelerated advancement.
--
-- It is an instantiation of a discard_block_engine with
-- ranlux24_base, with parameters p=223 and r=23.
module ranlux24: rng_engine with int.t = u32 =
  discard_block_engine {let p = 223 let r = 23} ranlux24_base

-- | A subtract-with-carry pseudo-random generator of 48-bit numbers
-- with accelerated advancement.
--
-- It is an instantiation of a discard_block_engine with
-- ranlux48_base, with parameters p=223 and r=23.
module ranlux48: rng_engine with int.t = u64 =
  discard_block_engine {let p = 389 let r = 11} ranlux48_base

-- | An engine adaptor that returns shuffled sequences generated with
-- minstd_rand0.  It is not a good idea to use this RNG in a parallel
-- setting, as the state size is fairly large.
module knuth_b: rng_engine with int.t = u32 =
  shuffle_order_engine {let k = 256} minstd_rand0

-- | This uniform integer distribution generates integers in a given
-- range with equal probability for each.
module uniform_int_distribution (D: integral) (E: rng_engine):
  rng_distribution with num.t = D.t
                   with engine.rng = E.rng
                   with distribution = (D.t,D.t) = {

  let to_D (x: E.int.t) = D.i64 (E.int.to_i64 x)
  let to_E (x: D.t) = E.int.i64 (D.to_i64 x)

  module engine = E
  module num = D
  type distribution = (D.t,D.t) -- Lower and upper bounds.
  let uniform (min: D.t) (max: D.t) = (min,max)

  open E.int

  let rand ((min,max): distribution) (rng: E.rng) =
    let min = to_E min
    let max = to_E max
    let range = max - min + i32 1
    in if range <= i32 0
       then (rng, to_D E.min) -- Avoid infinite loop below.
       else let secure_max = E.max - E.max %% range
            let (rng,x) = loop (rng, x) = E.rand rng
                          while x >= secure_max do E.rand rng
            in (rng, to_D (min + x / (secure_max / range)))
}

-- | This uniform integer distribution generates floats in a given
-- range with "equal" probability for each.
module uniform_real_distribution (R: real) (E: rng_engine):
  rng_distribution with num.t = R.t
                   with engine.rng = E.rng
                   with distribution = (R.t,R.t) = {
  let to_D (x: E.int.t) = R.i64 (E.int.to_i64 x)

  module engine = E
  module num = R
  type distribution = (num.t, num.t) -- Lower and upper bounds.

  let uniform (min: num.t) (max: num.t) = (min, max)

  let rand ((min_r,max_r): distribution) (rng: E.rng) =
    let (rng', x) = E.rand rng
    let x' = to_D x R./ to_D E.max
    in (rng', R.(min_r + x' * (max_r - min_r)))
}

module normal_distribution (R: real) (E: rng_engine):
  rng_distribution with num.t = R.t
                   with engine.rng = E.rng
                   with distribution = {mean:R.t,stddev:R.t} = {
  let to_R (x: E.int.t) = R.i64 (E.int.to_i64 x)

  module engine = E
  module num = R
  type distribution = {mean: num.t, stddev: num.t}

  let normal (mean: num.t) (stddev: num.t) = {mean=mean, stddev=stddev}

  open R

  let rand ({mean,stddev}: distribution) (rng: E.rng) =
    -- Box-Muller where we only use one of the generated points.
    let (rng, u1) = E.rand rng
    let (rng, u2) = E.rand rng
    let u1 = to_R u1 / to_R E.max
    let u2 = to_R u2 / to_R E.max
    let r = sqrt (i32 (-2) * log u1)
    let theta = i32 2 * pi * u2
    in (rng, mean + stddev * (r * cos theta))
}
