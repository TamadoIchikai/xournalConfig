-- Pure-Lua gzip (RFC 1952) / raw-DEFLATE (RFC 1951) decompressor.
-- Requires Lua 5.3+ native bitwise operators (&, |, ~, <<, >>).

local M = {}

local ceil, find, sub, byte, char, concat
    = math.ceil, string.find, string.sub, string.byte, string.char, table.concat

local MAXBITS = 15
local FLUSH   = 8192
local LITBUF  = 4096

-- ========================= Bit reader (LSB-first) =========================

local BitReader = {}
BitReader.__index = BitReader

function BitReader.new(data)
  return setmetatable({
    data = data, pos = 1, bitbuf = 0, bitcnt = 0, len = #data, total = 0,
  }, BitReader)
end

function BitReader:need(n)
  while self.bitcnt < n do
    if self.pos > self.len then error("inflate: input truncated", 0) end
    local b = self.data:byte(self.pos); self.pos = self.pos + 1
    self.bitbuf = self.bitbuf | (b << self.bitcnt)
    self.bitcnt = self.bitcnt + 8
  end
end

function BitReader:bits(n)
  self:need(n)
  local v = self.bitbuf & ((1 << n) - 1)
  self.bitbuf = self.bitbuf >> n
  self.bitcnt = self.bitcnt - n
  self.total = self.total + n
  return v
end

-- Discard bits until the next byte boundary (required before stored blocks).
function BitReader:align()
  local skip = (8 - (self.total % 8)) % 8
  if skip > 0 then self:bits(skip) end
end

function BitReader:rawBytes(n)
  self.bitbuf = 0; self.bitcnt = 0
  if self.pos + n - 1 > self.len then error("inflate: stored block OOB", 0) end
  local s = sub(self.data, self.pos, self.pos + n - 1)
  self.pos = self.pos + n; return s
end

-- ========================= Huffman ========================================

local function build_huffman(lengths)
  local count, offs, maxlen = {}, {}, 0
  for i = 1, MAXBITS do count[i] = 0 end
  for i = 1, #lengths do
    local l = lengths[i]
    if l and l > 0 then count[l] = count[l] + 1; if l > maxlen then maxlen = l end end
  end
  if maxlen == 0 then return { maxlen = 0, count = count, symbol = {} } end
  offs[1] = 0
  for len = 1, MAXBITS - 1 do offs[len + 1] = offs[len] + count[len] end
  local symbol = {}
  for i = 1, #lengths do
    local l = lengths[i]
    if l and l > 0 then offs[l] = offs[l] + 1; symbol[offs[l]] = i - 1 end
  end
  return { maxlen = maxlen, count = count, symbol = symbol }
end

local function huff_decode(br, h)
  local code, first, index = 0, 0, 0
  for len = 1, h.maxlen do
    code = code | br:bits(1)
    local c = h.count[len]
    if code - c < first then return h.symbol[index + (code - first) + 1] end
    index = index + c; first = (first + c) << 1; code = code << 1
  end
  return -1
end

-- Fixed codes (RFC 1951 3.2.6)
local FIXED_LIT, FIXED_DIST
do
  local lit, dist = {}, {}
  for s = 0, 143 do lit[s + 1] = 8 end
  for s = 144, 255 do lit[s + 1] = 9 end
  for s = 256, 279 do lit[s + 1] = 7 end
  for s = 280, 287 do lit[s + 1] = 8 end
  for s = 0, 29 do dist[s + 1] = 5 end
  FIXED_LIT  = build_huffman(lit)
  FIXED_DIST = build_huffman(dist)
end

local LENGTH_BASE  = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,
                      67,83,99,115,131,163,195,227,258}
local LENGTH_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,
                      4,4,4,4,5,5,5,5,0}
local DIST_BASE    = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,
                      257,385,513,769,1025,1537,2049,3073,4097,
                      6145,8193,12289,16385,24577}
local DIST_EXTRA   = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,
                      9,9,10,10,11,11,12,12,13,13}
local CL_ORDER = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

-- ========================= Output accumulator ==============================

local function acc_new()
  return { parts = {}, tail = "" }
end

local function acc_back(a, dist)
  if #a.tail >= dist then
    return sub(a.tail, #a.tail - dist + 1, #a.tail)
  end
  local buf, need = {}, dist - #a.tail
  buf[#buf + 1] = a.tail
  local i = #a.parts
  while need > 0 and i >= 1 do
    local c = a.parts[i]
    if #c >= need then
      buf[#buf + 1] = sub(c, #c - need + 1, #c); need = 0
    else
      buf[#buf + 1] = c; need = need - #c
    end
    i = i - 1
  end
  if need > 0 then error("inflate: back-ref distance exceeds output", 0) end
  local result, k = {}, #buf
  for j = 1, k do result[j] = buf[k - j + 1] end
  return concat(result)
end

local function acc_append(a, s)
  if #a.tail + #s >= FLUSH then
    if #a.tail > 0 then a.parts[#a.parts + 1] = a.tail end
    a.tail = s
  else
    a.tail = a.tail .. s
  end
end

local function acc_finish(a)
  a.parts[#a.parts + 1] = a.tail
  return concat(a.parts)
end

-- ========================= Dynamic Huffman ================================

local function read_dynamic(br)
  local hlit  = br:bits(5) + 257
  local hdist = br:bits(5) + 1
  local hclen = br:bits(4) + 4

  local cl = {}; for i = 1, 19 do cl[i] = 0 end
  for i = 1, hclen do cl[CL_ORDER[i] + 1] = br:bits(3) end
  local cl_huff = build_huffman(cl)
  if cl_huff.maxlen == 0 then return nil, "empty code-length code" end

  local lens = {}
  local rem = hlit + hdist
  while rem > 0 do
    local sym = huff_decode(br, cl_huff)
    if sym < 0 then return nil, "invalid code-length code" end
    if sym < 16 then
      lens[#lens + 1] = sym; rem = rem - 1
    elseif sym == 16 then
      local p = #lens > 0 and lens[#lens] or 0
      local r = 3 + br:bits(2); if r > rem then r = rem end
      for i = 1, r do lens[#lens + 1] = p end; rem = rem - r
    elseif sym == 17 then
      local r = 3 + br:bits(3); if r > rem then r = rem end
      for i = 1, r do lens[#lens + 1] = 0 end; rem = rem - r
    else
      local r = 11 + br:bits(7); if r > rem then r = rem end
      for i = 1, r do lens[#lens + 1] = 0 end; rem = rem - r
    end
  end

  local lit_len, dist_len = {}, {}
  for i = 1, hlit do  lit_len[i] = lens[i] end
  for i = 1, hdist do dist_len[i] = lens[hlit + i] end

  local lit = build_huffman(lit_len)
  if lit.maxlen == 0 then return nil, "empty literal code" end
  return lit, build_huffman(dist_len)
end

-- ========================= Inflate core ====================================

local function inflate_br(br, acc)
  local litbuf = {}      -- owned by this function (no aliasing surprises)

  while true do
    local bfinal = br:bits(1)
    local btype  = br:bits(2)

    if btype == 0 then
      br:align()
      local len = br:bits(16)
      br:bits(16) -- NLEN
      if #litbuf > 0 then acc_append(acc, concat(litbuf)); litbuf = {} end
      acc_append(acc, br:rawBytes(len))
    else
      local lit_code, dist_code
      if btype == 1 then
        lit_code, dist_code = FIXED_LIT, FIXED_DIST
      elseif btype == 2 then
        local lc, dc = read_dynamic(br)
        if not lc then return nil, (dc or "invalid dynamic block") end
        lit_code, dist_code = lc, dc
      else
        return nil, "invalid block type"
      end

      while true do
        local sym = huff_decode(br, lit_code)
        if sym < 0 then return nil, "invalid literal/length code" end
        if sym < 256 then
          litbuf[#litbuf + 1] = char(sym)
          if #litbuf >= LITBUF then
            acc_append(acc, concat(litbuf)); litbuf = {}
          end
        elseif sym == 256 then
          break
        else
          local li = sym - 256
          local length = LENGTH_BASE[li] + br:bits(LENGTH_EXTRA[li])
          local ds = huff_decode(br, dist_code)
          if ds < 0 then return nil, "invalid distance code" end
          local dist = DIST_BASE[ds + 1] + br:bits(DIST_EXTRA[ds + 1])
          if #litbuf > 0 then acc_append(acc, concat(litbuf)); litbuf = {} end
          local src = acc_back(acc, dist)
          local reps = ceil(length / #src)
          acc_append(acc, (src:rep(reps)):sub(1, length))
        end
      end
    end

    if bfinal == 1 then
      break
    end
  end

  -- Flush any literal bytes decoded just before end-of-block.
  if #litbuf > 0 then acc_append(acc, concat(litbuf)) end
  return true
end

-- ========================= Gzip parser ====================================

function M.gunzip(data)
  if #data < 18 then return nil, "not a gzip file (too short)" end
  if data:byte(1) ~= 0x1f or data:byte(2) ~= 0x8b then
    return nil, "not a gzip file"
  end
  if data:byte(3) ~= 8 then
    return nil, "unsupported compression method"
  end

  local flags = data:byte(4)
  local pos = 11

  local FEXTRA   = 0x04
  local FNAME    = 0x08
  local FCOMMENT = 0x10
  local FHCRC    = 0x02

  if flags & FEXTRA ~= 0 then
    local xlen = data:byte(pos) * 256 + data:byte(pos + 1)
    pos = pos + 2 + xlen
    if pos > #data then return nil, "gzip extra field too long" end
  end
  if flags & FNAME ~= 0 then
    local e = find(data, "\0", pos, true)
    if not e then return nil, "gzip filename unterminated" end
    pos = e + 1
  end
  if flags & FCOMMENT ~= 0 then
    local e = find(data, "\0", pos, true)
    if not e then return nil, "gzip comment unterminated" end
    pos = e + 1
  end
  if flags & FHCRC ~= 0 then
    pos = pos + 2
  end

  if pos + 8 > #data then return nil, "gzip trailer missing" end
  local body = sub(data, pos, #data - 8)

  local br = BitReader.new(body)
  local acc = acc_new()
  local ok, result, msg = pcall(inflate_br, br, acc)
  if not ok then return nil, "inflate: " .. tostring(result) end
  if result ~= true then return nil, "inflate: " .. tostring(result or msg) end

  return acc_finish(acc)
end

return M
