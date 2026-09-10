/**
 * 极简 MD5 实现（仅用于文件完整性校验，非安全用途）
 *
 * 为什么不用 Web Crypto：crypto.subtle 只支持 SHA-1/SHA-256 系列，不提供 MD5，
 * 而协议里与 Flutter 端（package:crypto 的 md5）约定的就是 MD5，两端必须一致。
 *
 * @param {Uint8Array} bytes
 * @returns {string} 32 位小写十六进制
 */

/** 每轮左移位数 */
const S = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
]

/**
 * T[i] = floor(2^32 * abs(sin(i + 1)))，预先用 Math 计算，
 * 避免硬编码 64 个魔数常量出错。
 */
const T = (() => {
  const t = new Uint32Array(64)
  for (let i = 0; i < 64; i++) {
    t[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0
  }
  return t
})()

function rotateLeft(x, n) {
  return ((x << n) | (x >>> (32 - n))) >>> 0
}

/**
 * 把一个 32 位状态字按「小端字节序」输出为 8 位十六进制。
 *
 * MD5 的 A/B/C/D 累加值本身是小端解释的，直接 toString(16) 会得到字节反序的结果
 * （实测：会算成 d98c1dd4... 而正确摘要是 d41d8cd9...），必须逐字节从低到高取。
 */
function toHex(n) {
  let s = ''
  for (let i = 0; i < 4; i++) {
    s += ((n >>> (i * 8)) & 0xff).toString(16).padStart(2, '0')
  }
  return s
}

/**
 * 计算 MD5
 * @param {Uint8Array} bytes
 * @returns {string}
 */
export function md5(bytes) {
  // 初始魔数（小端序下的 A B C D）
  let a0 = 0x67452301
  let b0 = 0xefcdab89
  let c0 = 0x98badcfe
  let d0 = 0x10325476

  // 补位：原始数据 + 0x80 + 若干个 0，使长度 ≡ 56 (mod 64)，再追加 8 字节位长
  const bitLen = bytes.length * 8
  const withPad = new Uint8Array((((bytes.length + 8) >> 6) + 1) << 6)
  withPad.set(bytes)
  withPad[bytes.length] = 0x80
  // 低 64 位中的低 32 位写入第 56 字节处（小端）；本应用文件 < 512MB，高 32 位恒为 0
  const dv = new DataView(withPad.buffer)
  dv.setUint32(withPad.length - 8, bitLen >>> 0, true)
  dv.setUint32(withPad.length - 4, Math.floor(bitLen / 4294967296), true)

  const mdv = new DataView(withPad.buffer)
  for (let chunk = 0; chunk < withPad.length; chunk += 64) {
    const M = new Uint32Array(16)
    for (let j = 0; j < 16; j++) {
      M[j] = mdv.getUint32(chunk + j * 4, true)
    }

    let [A, B, C, D] = [a0, b0, c0, d0]

    for (let i = 0; i < 64; i++) {
      let F
      let g
      if (i < 16) {
        F = (B & C) | (~B & D)
        g = i
      } else if (i < 32) {
        F = (D & B) | (~D & C)
        g = (5 * i + 1) % 16
      } else if (i < 48) {
        F = B ^ C ^ D
        g = (3 * i + 5) % 16
      } else {
        F = C ^ (B | ~D)
        g = (7 * i) % 16
      }
      F = F >>> 0
      const tmp = D
      D = C
      C = B
      B = (B + rotateLeft((((A + F + T[i] + M[g]) >>> 0) >>> 0), S[i])) >>> 0
      A = tmp
    }

    a0 = (a0 + A) >>> 0
    b0 = (b0 + B) >>> 0
    c0 = (c0 + C) >>> 0
    d0 = (d0 + D) >>> 0
  }

  return toHex(a0) + toHex(b0) + toHex(c0) + toHex(d0)
}
