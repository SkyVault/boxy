#version 100 // Used for emscripten.

precision highp float;

varying vec2 pos;
varying vec2 uv;
varying vec4 color;

uniform vec2 windowFrame;
uniform sampler2D atlasTex;
uniform sampler2D maskTex;

void main() {
  gl_FragColor = texture2D(atlasTex, uv).rgba * color;
  vec2 normalizedPos = vec2(pos.x / windowFrame.x, 1.0 - pos.y / windowFrame.y);
  gl_FragColor *= texture2D(maskTex, normalizedPos).r;
}
