-- A local function may not consume anything free.
-- ==
-- error: QUUX.*consumed

fun main(y: i32, QUUX: *[]i32) =
  let f (x: i32) = let QUUX[0] = x in x
  in f y
