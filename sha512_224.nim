import std/[endians, strutils]

include sha2

# NOTE: a truncated version of SHA-512 with a different set of initial values, producing a 224-bit digest

const wordSize = 8
const blockSize = 128
const scheduleSize = 80

# NOTE: schedule array
var w: array[scheduleSize, uint64]

type
  Sha512_224Context* = object
    state*: array[8, uint64]
    buffer: array[blockSize, uint8]
    bufferIdx: int  # NOTE: tracks the number of bytes currently in the buffer
    totalLen: int64 # NOTE: total length of the message

const initState: array[8, uint64] = [
    0x8C3D37C819544DA2'u64, 0x73E1996689DCD4D6'u64, 0x1DFAB7AE32FF9C82'u64, 0x679DD514582F9FCF'u64,
    0x0F6D2B697BD44DA8'u64, 0x77E36F7304C48942'u64, 0x3F9D85A86A1D36C8'u64, 0x1112E6AD91D692A1'u64
]
# NOTE: round constants
const k: array[80, uint64] = [
    0x428a2f98d728ae22'u64, 0x7137449123ef65cd'u64, 0xb5c0fbcfec4d3b2f'u64, 0xe9b5dba58189dbbc'u64,
    0x3956c25bf348b538'u64, 0x59f111f1b605d019'u64, 0x923f82a4af194f9b'u64, 0xab1c5ed5da6d8118'u64,
    0xd807aa98a3030242'u64, 0x12835b0145706fbe'u64, 0x243185be4ee4b28c'u64, 0x550c7dc3d5ffb4e2'u64,
    0x72be5d74f27b896f'u64, 0x80deb1fe3b1696b1'u64, 0x9bdc06a725c71235'u64, 0xc19bf174cf692694'u64,
    0xe49b69c19ef14ad2'u64, 0xefbe4786384f25e3'u64, 0x0fc19dc68b8cd5b5'u64, 0x240ca1cc77ac9c65'u64,
    0x2de92c6f592b0275'u64, 0x4a7484aa6ea6e483'u64, 0x5cb0a9dcbd41fbd4'u64, 0x76f988da831153b5'u64,
    0x983e5152ee66dfab'u64, 0xa831c66d2db43210'u64, 0xb00327c898fb213f'u64, 0xbf597fc7beef0ee4'u64,
    0xc6e00bf33da88fc2'u64, 0xd5a79147930aa725'u64, 0x06ca6351e003826f'u64, 0x142929670a0e6e70'u64,
    0x27b70a8546d22ffc'u64, 0x2e1b21385c26c926'u64, 0x4d2c6dfc5ac42aed'u64, 0x53380d139d95b3df'u64,
    0x650a73548baf63de'u64, 0x766a0abb3c77b2a8'u64, 0x81c2c92e47edaee6'u64, 0x92722c851482353b'u64,
    0xa2bfe8a14cf10364'u64, 0xa81a664bbc423001'u64, 0xc24b8b70d0f89791'u64, 0xc76c51a30654be30'u64,
    0xd192e819d6ef5218'u64, 0xd69906245565a910'u64, 0xf40e35855771202a'u64, 0x106aa07032bbd1b8'u64,
    0x19a4c116b8d2d0c8'u64, 0x1e376c085141ab53'u64, 0x2748774cdf8eeb99'u64, 0x34b0bcb5e19b48a8'u64,
    0x391c0cb3c5c95a63'u64, 0x4ed8aa4ae3418acb'u64, 0x5b9cca4f7763e373'u64, 0x682e6ff3d6b2b8a3'u64,
    0x748f82ee5defb2fc'u64, 0x78a5636f43172f60'u64, 0x84c87814a1f0ab72'u64, 0x8cc702081a6439ec'u64,
    0x90befffa23631e28'u64, 0xa4506cebde82bde9'u64, 0xbef9a3f7b2c67915'u64, 0xc67178f2e372532b'u64,
    0xca273eceea26619c'u64, 0xd186b8c721c0c207'u64, 0xeada7dd6cde0eb1e'u64, 0xf57d4f7fee6ed178'u64,
    0x06f067aa72176fba'u64, 0x0a637dc5a2c898a6'u64, 0x113f9804bef90dae'u64, 0x1b710b35131c471b'u64,
    0x28db77f523047d84'u64, 0x32caab7b40c72493'u64, 0x3c9ebe0a15c9bebc'u64, 0x431d67c49c100d4c'u64,
    0x4cc5d4becb3e42b6'u64, 0x597f299cfc657e2a'u64, 0x5fcb6fab3ad6faec'u64, 0x6c44198c4a475817'u64
  ]


proc schedule(i: int): uint64 {.inline.} =
  ## modify message schedule values
  return sigma1(w[i - 2]) + w[i - 7] + sigma0(w[i - 15]) + w[i - 16]


proc padBuffer(ctx: var Sha512_224Context) =
  ## pad data in the buffer
  # NOTE: pad with zeros until the last 64 bits
  while ctx.bufferIdx < blockSize - 16:  # -16 for the 64-bit length at the end
    ctx.buffer[ctx.bufferIdx] = 0'u8
    inc ctx.bufferIdx

  # NOTE: add the original message length as a 128-bit big-endian integer
  # NOTE: upper 64 bits of the 128-bit length field are set to zero
  for i in countdown(15, 8):
    ctx.buffer[ctx.bufferIdx] = 0'u8
    inc ctx.bufferIdx
  
  # NOTE: add the lower 64 bits of the message length to the buffer
  let msgBitLength = uint64(ctx.totalLen * 8)
  for i in countdown(7, 0):
    ctx.buffer[ctx.bufferIdx] = uint8((msgBitLength shr (i * 8)) and 0xff'u64)
    inc ctx.bufferIdx


proc compress(ctx: var Sha512_224Context) =
  ## process single 1024 bit block
  # NOTE: fill in first 16 words in big endian64 format
  for i in 0 ..< 16:
    bigEndian64(addr w[i], addr ctx.buffer[i * wordSize])

  # NOTE: fill in remaining 112
  for i in 16 ..< scheduleSize:
    w[i] = schedule(i)

  # NOTE: initialize working variables to current hash value
  var a = ctx.state[0]
  var b = ctx.state[1]
  var c = ctx.state[2]
  var d = ctx.state[3]
  var e = ctx.state[4]
  var f = ctx.state[5]
  var g = ctx.state[6]
  var h = ctx.state[7]

  # NOTE: compression
  var temp1: uint64
  var temp2: uint64
  for i in 0 ..< scheduleSize:
    temp1 = h + Sigma1(e) + choice(e, f, g) + k[i] + w[i]
    temp2 = Sigma0(a) + majority(a, b, c)
    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2

  # NOTE: add the compressed chunk to the current hash value
  ctx.state[0] += a
  ctx.state[1] += b
  ctx.state[2] += c
  ctx.state[3] += d
  ctx.state[4] += e
  ctx.state[5] += f
  ctx.state[6] += g
  ctx.state[7] += h

  ctx.bufferIdx = 0


proc copyShaCtx*(toThisCtx: var Sha512_224Context, fromThisCtx: Sha512_224Context) =
  for idx, b in fromThisCtx.state:
    toThisCtx.state[idx] = b
  for idx, b in fromThisCtx.buffer:
    toThisCtx.buffer[idx] = b
  toThisCtx.bufferIdx = fromThisCtx.bufferIdx
  toThisCtx.totalLen = fromThisCtx.totalLen


proc update*[T](ctx: var Sha512_224Context, msg: openarray[T]) =
  ctx.totalLen.inc(msg.len)
  for i in 0 ..< msg.len:
    ctx.buffer[ctx.bufferIdx] = uint8(msg[i])
    inc ctx.bufferIdx
    if ctx.bufferIdx == blockSize:
      ctx.compress()


proc finalize*(ctx: var Sha512_224Context) =
  # NOTE: append the bit '1' to the buffer guaranteeing at least 1 byte free
  ctx.buffer[ctx.bufferIdx] = 0x80'u8
  inc ctx.bufferIdx
  
  # NOTE: if buffer contains more than blockSize - ctx.bufferIdx bytes ->
  # pad remaining space with zeros and compress
  # this ensures there is room for the length field
  let spaceLeft = blockSize - ctx.bufferIdx
  if spaceLeft < wordSize * 2:
    for i in 0 ..< spaceLeft:
      ctx.buffer[ctx.bufferIdx + i] = 0x00'u8
    ctx.compress()
  
  # NOTE: pad the remaining data in the buffer
  ctx.padBuffer()
  # NOTE: process the final block
  ctx.compress()


proc digest*(ctx: Sha512_224Context): array[28, uint8] =
  ## convert state array[8, uint64] to array[28, uint8]
  ## does not alter hash state
  var tempCtx: Sha512_224Context
  copyShaCtx(tempCtx, ctx)
  
  tempCtx.finalize()
  
  for idx in 0 ..< 6:
    bigEndian64(addr result[idx * wordSize], addr tempCtx.state[idx])
  return result


proc hexDigest*(ctx: Sha512_224Context): string =
  ## convert state array[8, uint64] to hex string of length 56
  ## does not alter hash state
  var tempCtx: Sha512_224Context
  copyShaCtx(tempCtx, ctx)
  
  tempCtx.finalize()
  result = newStringOfCap(56)
  for idx in 0 ..< 6:
    result.add(tempCtx.state[idx].toHex(16).toLowerAscii())
  return result[0 ..< 56]


proc newSha512_224Ctx*(msg: openarray[uint8] = @[]): Sha512_224Context =
  # NOTE: initialize state
  result.state = initState
  if msg.len > 0:
    result.update(msg)


proc newSha512_224Ctx*(msg: string): Sha512_224Context =
  return newSha512_224Ctx(msg.toOpenArrayByte(0, msg.len.pred))


when isMainModule:
  include testing/testing512_224
  
  proc runTestVectors() =
    for v in testVectors:
      let ctx = newSha512_224Ctx(v.Msg.parseHexStr())
      doAssert ctx.hexDigest() == v.MD

  runTestVectors()
