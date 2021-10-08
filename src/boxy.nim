import boxy/buffers, boxy/shaders, boxy/textures, bumpy, chroma, hashes, opengl,
    os, pixie, strformat, strutils, tables, vmath

export pixie

const
  quadLimit = 10_921
  tileSize = 32

type
  ImageInfo = object
    width: int      ## Width of the image in pixels.
    height: int     ## Height of the image in pixels.
    tiles: seq[int] ## Tile indexes to look for tiles.
    color: Color    ## If tiles = [] then this is the tile color.

  Boxy* = ref object
    atlasShader, maskShader, activeShader: Shader
    atlasTexture: Texture
    maskTextureWrite: int      ## Index into mask textures for writing.
    maskTextureRead: int       ## Index into mask textures for rendering.
    maskTextures: seq[Texture] ## Masks array for pushing and popping.
    atlasSize: int             ## Size x size dimensions of the atlas
    quadCount: int             ## Number of quads drawn so far
    maxQuads: int              ## Max quads to draw before issuing an OpenGL call
    mat: Mat4                  ## Current matrix
    mats: seq[Mat4]            ## Matrix stack
    entries*: Table[string, ImageInfo]
    maxTiles: int
    tileRun: int
    takenTiles: seq[bool]      ## Height map of the free space in the atlas
    proj: Mat4
    frameSize: Vec2            ## Dimensions of the window frame
    vertexArrayId, maskFramebufferId: GLuint
    frameBegun, maskBegun: bool
    pixelate: bool             ## Makes texture look pixelated, like a pixel game.

    # Buffer data for OpenGL
    positions: tuple[buffer: Buffer, data: seq[float32]]
    colors: tuple[buffer: Buffer, data: seq[uint8]]
    uvs: tuple[buffer: Buffer, data: seq[float32]]
    indices: tuple[buffer: Buffer, data: seq[uint16]]

proc vec2(x, y: SomeNumber): Vec2 =
  ## Integer short cut for creating vectors.
  vec2(x.float32, y.float32)

func `*`(m: Mat4, v: Vec2): Vec2 =
  (m * vec3(v.x, v.y, 0.0)).xy

proc `*`(a, b: Color): Color =
  result.r = a.r * b.r
  result.g = a.g * b.g
  result.b = a.b * b.b
  result.a = a.a * b.a

proc tileWidth(tileInfo: ImageInfo): int =
  ## Number of tiles wide.
  ceil(tileInfo.width / tileSize).int

proc tileHeight(tileInfo: ImageInfo): int =
  ## Number of tiles high.
  ceil(tileInfo.height / tileSize).int

proc readAtlas*(boxy: Boxy): Image =
  ## Read the current atlas content.
  result = newImage(boxy.atlasTexture.width, boxy.atlasTexture.height)
  glBindTexture(GL_TEXTURE_2D, boxy.atlasTexture.textureId)
  when not defined(emscripten):
    glGetTexImage(
      GL_TEXTURE_2D,
      0,
      GL_RGBA,
      GL_UNSIGNED_BYTE,
      result.data[0].addr
    )

proc upload(boxy: Boxy) =
  ## When buffers change, uploads them to GPU.
  boxy.positions.buffer.count = boxy.quadCount * 4
  boxy.colors.buffer.count = boxy.quadCount * 4
  boxy.uvs.buffer.count = boxy.quadCount * 4
  boxy.indices.buffer.count = boxy.quadCount * 6
  bindBufferData(boxy.positions.buffer, boxy.positions.data[0].addr)
  bindBufferData(boxy.colors.buffer, boxy.colors.data[0].addr)
  bindBufferData(boxy.uvs.buffer, boxy.uvs.data[0].addr)

proc draw(boxy: Boxy) =
  ## Flips - draws current buffer and starts a new one.
  if boxy.quadCount == 0:
    return

  boxy.upload()

  glUseProgram(boxy.activeShader.programId)
  glBindVertexArray(boxy.vertexArrayId)

  if boxy.activeShader.hasUniform("windowFrame"):
    boxy.activeShader.setUniform(
      "windowFrame", boxy.frameSize.x, boxy.frameSize.y
    )
  boxy.activeShader.setUniform("proj", boxy.proj)

  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, boxy.atlasTexture.textureId)
  boxy.activeShader.setUniform("atlasTex", 0)

  if boxy.activeShader.hasUniform("maskTex"):
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(
      GL_TEXTURE_2D,
      boxy.maskTextures[boxy.maskTextureRead].textureId
    )
    boxy.activeShader.setUniform("maskTex", 1)

  boxy.activeShader.bindUniforms()

  glBindBuffer(
    GL_ELEMENT_ARRAY_BUFFER,
    boxy.indices.buffer.bufferId
  )
  glDrawElements(
    GL_TRIANGLES,
    boxy.indices.buffer.count.GLint,
    boxy.indices.buffer.componentType,
    nil
  )

  boxy.quadCount = 0

proc setUpMaskFramebuffer(boxy: Boxy) =
  glBindFramebuffer(GL_FRAMEBUFFER, boxy.maskFramebufferId)
  glFramebufferTexture2D(
    GL_FRAMEBUFFER,
    GL_COLOR_ATTACHMENT0,
    GL_TEXTURE_2D,
    boxy.maskTextures[boxy.maskTextureWrite].textureId,
    0
  )

proc createAtlasTexture(boxy: Boxy, size: int): Texture =
  result = Texture()
  result.width = size.int32
  result.height = size.int32
  result.componentType = GL_UNSIGNED_BYTE
  result.format = GL_RGBA
  result.internalFormat = GL_RGBA8
  result.genMipmap = true
  result.minFilter = minLinearMipmapLinear
  if boxy.pixelate:
    result.magFilter = magNearest
  else:
    result.magFilter = magLinear
  bindTextureData(result, nil)

proc addMaskTexture(boxy: Boxy, frameSize = vec2(1, 1)) =
  # Must be >0 for framebuffer creation below
  # Set to real value in beginFrame
  let maskTexture = Texture()
  maskTexture.width = frameSize.x.int32
  maskTexture.height = frameSize.y.int32
  maskTexture.componentType = GL_UNSIGNED_BYTE
  maskTexture.format = GL_RGBA
  when defined(emscripten):
    maskTexture.internalFormat = GL_RGBA8
  else:
    maskTexture.internalFormat = GL_R8
  maskTexture.minFilter = minLinear
  if boxy.pixelate:
    maskTexture.magFilter = magNearest
  else:
    maskTexture.magFilter = magLinear
  bindTextureData(maskTexture, nil)
  boxy.maskTextures.add(maskTexture)

proc addSolidTile(boxy: Boxy) =
  # Insert solid color tile. (don't use addImage as its a solid color)
  let solidTile = newImage(tileSize, tileSize)
  solidTile.fill(color(1, 1, 1, 1))
  updateSubImage(
    boxy.atlasTexture,
    0,
    0,
    solidTile
  )
  boxy.takenTiles[0] = true

proc clearAtlas*(boxy: Boxy) =
  boxy.entries.clear()
  for index in 0 ..< boxy.maxTiles:
    if index != -1:
      boxy.takenTiles[index] = false
  boxy.addSolidTile()

proc newBoxy*(atlasSize = 512, maxQuads = 1024, pixelate = false): Boxy =
  ## Creates a new Boxy.
  if maxQuads > quadLimit:
    raise newException(ValueError, "Quads cannot exceed " & $quadLimit)

  result = Boxy()
  result.atlasSize = atlasSize
  result.maxQuads = maxQuads
  result.mat = mat4()
  result.mats = newSeq[Mat4]()
  result.pixelate = pixelate

  result.tileRun = atlasSize div tileSize
  result.maxTiles = result.tileRun * result.tileRun
  result.takenTiles = newSeq[bool](result.maxTiles)
  result.atlasTexture = result.createAtlasTexture(atlasSize)

  result.addMaskTexture()

  when defined(emscripten):
    result.atlasShader = newShaderStatic(
      "glsl/emscripten/atlas.vert",
      "glsl/emscripten/atlas.frag"
    )
    result.maskShader = newShaderStatic(
      "glsl/emscripten/atlas.vert",
      "glsl/emscripten/mask.frag"
    )
  else:
    result.atlasShader = newShaderStatic(
      "glsl/410/atlas.vert",
      "glsl/410/atlas.frag"
    )
    result.maskShader = newShaderStatic(
      "glsl/410/atlas.vert",
      "glsl/410/mask.frag"
    )

  result.positions.buffer = Buffer()
  result.positions.buffer.componentType = cGL_FLOAT
  result.positions.buffer.kind = bkVEC2
  result.positions.buffer.target = GL_ARRAY_BUFFER
  result.positions.data = newSeq[float32](
    result.positions.buffer.kind.componentCount() * maxQuads * 4
  )

  result.colors.buffer = Buffer()
  result.colors.buffer.componentType = GL_UNSIGNED_BYTE
  result.colors.buffer.kind = bkVEC4
  result.colors.buffer.target = GL_ARRAY_BUFFER
  result.colors.buffer.normalized = true
  result.colors.data = newSeq[uint8](
    result.colors.buffer.kind.componentCount() * maxQuads * 4
  )

  result.uvs.buffer = Buffer()
  result.uvs.buffer.componentType = cGL_FLOAT
  result.uvs.buffer.kind = bkVEC2
  result.uvs.buffer.target = GL_ARRAY_BUFFER
  result.uvs.data = newSeq[float32](
    result.uvs.buffer.kind.componentCount() * maxQuads * 4
  )

  result.indices.buffer = Buffer()
  result.indices.buffer.componentType = GL_UNSIGNED_SHORT
  result.indices.buffer.kind = bkSCALAR
  result.indices.buffer.target = GL_ELEMENT_ARRAY_BUFFER
  result.indices.buffer.count = maxQuads * 6

  for i in 0 ..< maxQuads:
    let offset = i * 4
    result.indices.data.add([
      (offset + 3).uint16,
      (offset + 0).uint16,
      (offset + 1).uint16,
      (offset + 2).uint16,
      (offset + 3).uint16,
      (offset + 1).uint16,
    ])

  # Indices are only uploaded once
  bindBufferData(result.indices.buffer, result.indices.data[0].addr)

  result.upload()

  result.activeShader = result.atlasShader

  glGenVertexArrays(1, result.vertexArrayId.addr)
  glBindVertexArray(result.vertexArrayId)

  result.activeShader.bindAttrib("vertexPos", result.positions.buffer)
  result.activeShader.bindAttrib("vertexColor", result.colors.buffer)
  result.activeShader.bindAttrib("vertexUv", result.uvs.buffer)

  # Create mask framebuffer
  glGenFramebuffers(1, result.maskFramebufferId.addr)
  result.setUpMaskFramebuffer()

  let status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
  if status != GL_FRAMEBUFFER_COMPLETE:
    quit(&"Something wrong with mask framebuffer: {toHex(status.int32, 4)}")

  glBindFramebuffer(GL_FRAMEBUFFER, 0)

  # Enable premultiplied alpha blending
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)

  result.addSolidTile()

proc grow(boxy: Boxy) =
  ## Grows the atlas size by 2 (growing area by 4).

  boxy.draw()

  # read old atlas content
  let
    oldAtlas = boxy.readAtlas()
    oldTileRun = boxy.tileRun

  boxy.atlasSize *= 2

  boxy.tileRun = boxy.atlasSize div tileSize
  boxy.maxTiles = boxy.tileRun * boxy.tileRun
  boxy.takenTiles.setLen(boxy.maxTiles)
  boxy.atlasTexture = boxy.createAtlasTexture(boxy.atlasSize)

  boxy.addSolidTile()

  for y in 0 ..< oldTileRun:
    for x in 0 ..< oldTileRun:
      let
        imageTile = oldAtlas.superImage(
          x * tileSize,
          y * tileSize,
          tileSize,
          tileSize
        )
        index = x + y * oldTileRun
      updateSubImage(
        boxy.atlasTexture,
        (index mod boxy.tileRun) * tileSize,
        (index div boxy.tileRun) * tileSize,
        imageTile
      )

proc findFreeTile(boxy: Boxy): int =
  for index in 0 ..< boxy.maxTiles:
    if not boxy.takenTiles[index]:
      boxy.takenTiles[index] = true
      return index

  boxy.grow()
  boxy.findFreeTile()

proc removeImage*(boxy: Boxy, key: string) =
  ## Removes an image, does nothing if the image has not been added.
  if key in boxy.entries:
    for index in boxy.entries[key].tiles:
      if index != -1:
        boxy.takenTiles[index] = false
    boxy.entries.del(key)

proc addImage*(boxy: Boxy, key: string, image: Image) =
  boxy.removeImage(key)

  var imageInfo: ImageInfo
  imageInfo.width = image.width
  imageInfo.height = image.height

  if image.isTransparent():
    imageInfo.color = color(0, 0, 0, 0)
  elif image.isOneColor():
    imageInfo.color = image[0, 0].color
  else:
    # Split the image into tiles.
    var firstSolid = true
    for y in 0 ..< imageInfo.tileHeight:
      for x in 0 ..< imageInfo.tileWidth:
        let tileImage = image.superImage(
          x * tileSize, y * tileSize, tileSize, tileSize
        )
        if tileImage.isOneColor():
          let tileColor = tileImage[0, 0].color
          if firstSolid:
            firstSolid = false
            imageInfo.color = tileColor
          if tileColor == imageInfo.color:
            imageInfo.tiles.add(-1)
            continue

        let index = boxy.findFreeTile()
        imageInfo.tiles.add(index)
        updateSubImage(
          boxy.atlasTexture,
          (index mod boxy.tileRun) * tileSize,
          (index div boxy.tileRun) * tileSize,
          tileImage
        )
        # Reminder: This does not set mipmaps (used for text, should it?)

  boxy.entries[key] = imageInfo

proc checkBatch(boxy: Boxy) =
  if boxy.quadCount == boxy.maxQuads:
    # This batch is full, draw and start a new batch.
    boxy.draw()

proc setVert(buf: var seq[float32], i: int, v: Vec2) =
  buf[i * 2 + 0] = v.x
  buf[i * 2 + 1] = v.y

proc setVertColor(buf: var seq[uint8], i: int, rgbx: ColorRGBX) =
  buf[i * 4 + 0] = rgbx.r
  buf[i * 4 + 1] = rgbx.g
  buf[i * 4 + 2] = rgbx.b
  buf[i * 4 + 3] = rgbx.a

proc drawQuad(
  boxy: Boxy,
  verts: array[4, Vec2],
  uvs: array[4, Vec2],
  colors: array[4, Color]
) =
  boxy.checkBatch()

  let offset = boxy.quadCount * 4
  boxy.positions.data.setVert(offset + 0, verts[0])
  boxy.positions.data.setVert(offset + 1, verts[1])
  boxy.positions.data.setVert(offset + 2, verts[2])
  boxy.positions.data.setVert(offset + 3, verts[3])

  boxy.uvs.data.setVert(offset + 0, uvs[0])
  boxy.uvs.data.setVert(offset + 1, uvs[1])
  boxy.uvs.data.setVert(offset + 2, uvs[2])
  boxy.uvs.data.setVert(offset + 3, uvs[3])

  boxy.colors.data.setVertColor(offset + 0, colors[0].asRgbx())
  boxy.colors.data.setVertColor(offset + 1, colors[1].asRgbx())
  boxy.colors.data.setVertColor(offset + 2, colors[2].asRgbx())
  boxy.colors.data.setVertColor(offset + 3, colors[3].asRgbx())

  inc boxy.quadCount

proc drawUvRect(boxy: Boxy, at, to, uvAt, uvTo: Vec2, color: Color) =
  ## Adds an image rect with a path to an ctx
  let
    at = boxy.mat * at
    to = boxy.mat * to
    posQuad = [
      vec2(at.x, to.y),
      vec2(to.x, to.y),
      vec2(to.x, at.y),
      vec2(at.x, at.y),
    ]
    uvAt = uvAt / boxy.atlasSize.float32
    uvTo = uvTo / boxy.atlasSize.float32
    uvQuad = [
      vec2(uvAt.x, uvTo.y),
      vec2(uvTo.x, uvTo.y),
      vec2(uvTo.x, uvAt.y),
      vec2(uvAt.x, uvAt.y),
    ]
    colorQuad = [color, color, color, color]

  boxy.drawQuad(posQuad, uvQuad, colorQuad)

proc drawImage*(
  boxy: Boxy,
  key: string,
  pos: Vec2,
  tintColor = color(1, 1, 1, 1),
  scale = 1.0
) =
  ## Draws image at pos from top-left. The image should have already been added.
  let tileInfo = boxy.entries[key]
  if tileInfo.tiles.len == 0:
    if tileInfo.color == color(0, 0, 0, 0):
      return # Don't draw anything if the image is transparent.
    # Draw a single solid-color rect
    boxy.drawUvRect(
      pos,
      pos + vec2(tileInfo.width, tileInfo.height),
      vec2(2, 2),
      vec2(2, 2),
      (tileInfo.color * tintColor)
    )
  else:
    var i = 0
    for y in 0 ..< tileInfo.tileHeight:
      for x in 0 ..< tileInfo.tileWidth:
        let
          index = tileInfo.tiles[i]
          posAt = pos + vec2(x * tileSize, y * tileSize)
        if index == -1:
          if tileInfo.color == color(0, 0, 0, 0):
            discard # Don't draw transparent tiles.
          else:
            # Draw solid color tile
            boxy.drawUvRect(
              posAt,
              posAt + vec2(tileSize, tileSize),
              vec2(2, 2),
              vec2(2, 2),
              (tileInfo.color * tintColor)
            )
        else:
          let
            uvAt = vec2(
              (index mod boxy.tileRun) * tileSize,
              (index div boxy.tileRun) * tileSize
            )
          boxy.drawUvRect(
            posAt,
            posAt + vec2(tileSize, tileSize),
            uvAt,
            uvAt + vec2(tileSize, tileSize),
            tintColor
          )
        inc i
    assert i == tileInfo.tiles.len

proc clearMask*(boxy: Boxy) =
  ## Sets mask off (actually fills the mask with white).
  assert boxy.frameBegun == true, "boxy.beginFrame has not been called."

  boxy.draw()

  boxy.setUpMaskFramebuffer()

  glClearColor(1, 1, 1, 1)
  glClear(GL_COLOR_BUFFER_BIT)

  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc beginMask*(boxy: Boxy) =
  ## Starts drawing into a mask.
  assert boxy.frameBegun == true, "boxy.beginFrame has not been called."
  assert boxy.maskBegun == false, "boxy.beginMask has already been called."
  boxy.maskBegun = true

  boxy.draw()

  inc boxy.maskTextureWrite
  boxy.maskTextureRead = boxy.maskTextureWrite - 1
  if boxy.maskTextureWrite >= boxy.maskTextures.len:
    boxy.addMaskTexture(boxy.frameSize)

  boxy.setUpMaskFramebuffer()
  glViewport(0, 0, boxy.frameSize.x.GLint, boxy.frameSize.y.GLint)

  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)

  boxy.activeShader = boxy.maskShader

proc endMask*(boxy: Boxy) =
  ## Stops drawing into the mask.
  assert boxy.maskBegun == true, "boxy.maskBegun has not been called."
  boxy.maskBegun = false

  boxy.draw()

  glBindFramebuffer(GL_FRAMEBUFFER, 0)

  boxy.maskTextureRead = boxy.maskTextureWrite
  boxy.activeShader = boxy.atlasShader

proc popMask*(boxy: Boxy) =
  boxy.draw()

  dec boxy.maskTextureWrite
  boxy.maskTextureRead = boxy.maskTextureWrite

proc beginFrame*(boxy: Boxy, frameSize: Vec2, proj: Mat4) =
  ## Starts a new frame.
  assert boxy.frameBegun == false, "boxy.beginFrame has already been called."
  boxy.frameBegun = true

  boxy.proj = proj

  if boxy.maskTextures[0].width != frameSize.x.int32 or
    boxy.maskTextures[0].height != frameSize.y.int32:
    # Resize all of the masks.
    boxy.frameSize = frameSize
    for i in 0 ..< boxy.maskTextures.len:
      boxy.maskTextures[i].width = frameSize.x.int32
      boxy.maskTextures[i].height = frameSize.y.int32
      if i > 0:
        # Never resize the 0th mask because its just white.
        bindTextureData(boxy.maskTextures[i], nil)

  glViewport(0, 0, boxy.frameSize.x.GLint, boxy.frameSize.y.GLint)

  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)

  boxy.clearMask()

proc beginFrame*(boxy: Boxy, frameSize: Vec2) =
  beginFrame(
    boxy,
    frameSize,
    ortho(0.float32, frameSize.x, frameSize.y, 0, -1000, 1000)
  )

proc endFrame*(boxy: Boxy) =
  ## Ends a frame.
  assert boxy.frameBegun == true, "boxy.beginFrame was not called first."
  assert boxy.maskTextureRead == 0, "Not all masks have been popped."
  assert boxy.maskTextureWrite == 0, "Not all masks have been popped."
  boxy.frameBegun = false

  boxy.draw()

proc translate*(boxy: Boxy, v: Vec2) =
  ## Translate the internal transform.
  boxy.mat = boxy.mat * translate(vec3(v))

proc rotate*(boxy: Boxy, angle: float32) =
  ## Rotates the internal transform.
  boxy.mat = boxy.mat * rotateZ(angle)

proc scale*(boxy: Boxy, scale: float32) =
  ## Scales the internal transform.
  boxy.mat = boxy.mat * scale(vec3(scale))

proc scale*(boxy: Boxy, scale: Vec2) =
  ## Scales the internal transform.
  boxy.mat = boxy.mat * scale(vec3(scale.x, scale.y, 1))

proc saveTransform*(boxy: Boxy) =
  ## Pushes a transform onto the stack.
  boxy.mats.add boxy.mat

proc restoreTransform*(boxy: Boxy) =
  ## Pops a transform off the stack.
  boxy.mat = boxy.mats.pop()

proc clearTransform*(boxy: Boxy) =
  ## Clears transform and transform stack.
  boxy.mat = mat4()
  boxy.mats.setLen(0)

proc fromScreen*(boxy: Boxy, windowFrame: Vec2, v: Vec2): Vec2 =
  ## Takes a point from screen and translates it to point inside the current transform.
  (boxy.mat.inverse() * vec3(v.x, windowFrame.y - v.y, 0)).xy

proc toScreen*(boxy: Boxy, windowFrame: Vec2, v: Vec2): Vec2 =
  ## Takes a point from current transform and translates it to screen.
  result = (boxy.mat * vec3(v.x, v.y, 1)).xy
  result.y = -result.y + windowFrame.y
