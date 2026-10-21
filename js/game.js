/* MSX DOOM — protótipo 2.5D em Three.js com as restrições do V9968 + Geo3D.
 *
 * O que este arquivo imita do hardware (ver README.md):
 *   - janela 3D de 256x180 dentro do SCREEN 8 (256x212), ampliada sem filtro;
 *   - arte INDEXADA: texturas e sprites são mapas de índices 0..15 e a cor final sai de
 *     uma paleta EPAL de 256 entradas x 15 bits (16 conjuntos de 16 cores);
 *   - Geo3D: o mundo é uma lista de quads texturizados, sombreamento chapado com 7 níveis
 *     por face (0..6), no máximo 255 faces por RUN;
 *   - inimigos/arma como sprites modo 3 (planos de 16 px de largura, cor 0 transparente).
 * O que NÃO imita: z-buffer (o Geo3D usa ordenação de pintor), recorte no plano próximo
 * e o limite de 16 planos de sprite por linha.
 */
(function () {
  'use strict';

  var THREE = window.THREE;
  var ASSETS = window.MSXDOOM_ASSETS;
  var params = new URLSearchParams(window.location.search);

  // ---------------------------------------------------------------- alvo V9968 / Geo3D
  var VIEW_W = 256, VIEW_H = 180;        // registradores W / H do Geo3D
  var FOCAL = 128;                       // registrador F: 128 px => 90 graus na horizontal
  var MAX_FACES = 255;                   // limite de faces por RUN
  var MAX_LEVEL = 6;                     // 7 níveis de luz = 7 cópias pré-sombreadas da textura
  var SPRITE_PLANES = 64;                // planos de sprite no modo 3
  var DRAW_DIST = 12;                    // alcance de visão em células
  var NUM_RAYS = 192;                    // raios do teste de visibilidade

  // ---------------------------------------------------------------- mapa
  // # aço   T painel técnico (emite luz vermelha)   R rocha marciana
  // . piso  L piso com luminária no teto            P jogador
  // f demônio   z técnico possuído   + kit médico
  var MAP = [
    '########################',
    '#...#.......T....#RRRRR#',
    '#.P.#..z....T....#R...R#',
    '#.L....L............f.R#',
    '#...#.......T.L..#R.L.R#',
    '#...#..+....T....#R...R#',
    '##.####.#####.####RR.RR#',
    '#.....T....L.....T...L.#',
    '#.L.........z..........#',
    '###.#####T###.####R.RRR#',
    '#...f...#..z.....#R....R',
    '#.L...L.....L..L....L.fR',
    '#.......#..##....#R....R',
    '#..z..+.#..##..f.#R.z..R',
    '#.......T........TR...+R',
    '#########TT######RRRRRRR'
  ];
  var MAP_W = MAP[0].length, MAP_H = MAP.length;
  var WALL_TEX = { '#': 'wall_steel', 'T': 'wall_tech', 'R': 'wall_rock' };

  var ENEMY_TYPES = {
    f: { name: 'fiend',  hp: 40, speed: 2.3, damage: 14, reach: 0.95, radius: 0.28 },
    z: { name: 'zombie', hp: 30, speed: 1.3, damage: 9,  reach: 0.90, radius: 0.28 }
  };

  var PLAYER_RADIUS = 0.22, PLAYER_SPEED = 3.2, TURN_SPEED = 2.4, MOUSE_SENS = 0.0025;
  var FIRE_DELAY = 0.32, MEDKIT_HEAL = 25;

  // luz: nível = AMBIENT + lâmpadas + "lanterna" do jogador, arredondado para 0..6
  var AMBIENT = 1.3, PLAYER_LIGHT = 3.2, PLAYER_LIGHT_RANGE = 7;
  var LAMP_POWER = 3.6, LAMP_RANGE = 4.5, TECH_POWER = 1.5, TECH_RANGE = 2.6;

  var grid = new Uint8Array(MAP_W * MAP_H);        // 0 = livre, senão código do caractere da parede
  var spawn = { x: 1.5, z: 1.5 };
  var enemySpawns = [], itemSpawns = [], lights = [];

  (function parseMap() {
    for (var z = 0; z < MAP_H; z++) {
      if (MAP[z].length !== MAP_W) throw new Error('MAP: linha ' + z + ' tem largura diferente');
      for (var x = 0; x < MAP_W; x++) {
        var ch = MAP[z][x];
        if (WALL_TEX[ch]) {
          grid[z * MAP_W + x] = ch.charCodeAt(0);
          if (ch === 'T') lights.push({ x: x + 0.5, z: z + 0.5, power: TECH_POWER, range: TECH_RANGE, lamp: false, flicker: false, now: 1 });
        } else if (ch === 'P') { spawn.x = x + 0.5; spawn.z = z + 0.5; }
        else if (ENEMY_TYPES[ch]) enemySpawns.push({ type: ch, x: x + 0.5, z: z + 0.5 });
        else if (ch === '+') itemSpawns.push({ x: x + 0.5, z: z + 0.5 });
        else if (ch === 'L') lights.push({ x: x + 0.5, z: z + 0.5, power: LAMP_POWER, range: LAMP_RANGE, lamp: true, flicker: lights.length % 3 === 1, now: 1 });
      }
    }
  })();

  function isWall(cx, cz) {
    return cx < 0 || cz < 0 || cx >= MAP_W || cz >= MAP_H || grid[cz * MAP_W + cx] !== 0;
  }
  function blocked(x, z, r) {
    return isWall(Math.floor(x - r), Math.floor(z - r)) || isWall(Math.floor(x + r), Math.floor(z - r)) ||
           isWall(Math.floor(x - r), Math.floor(z + r)) || isWall(Math.floor(x + r), Math.floor(z + r));
  }
  function moveCircle(e, dx, dz, r) {
    if (!blocked(e.x + dx, e.z, r)) e.x += dx;
    if (!blocked(e.x, e.z + dz, r)) e.z += dz;
  }

  // DDA na grade. Devolve a distância até a primeira parede (ou maxDist) e chama
  // visit(célula) para cada célula livre atravessada.
  function castRay(ox, oz, dx, dz, maxDist, visit) {
    var cx = Math.floor(ox), cz = Math.floor(oz);
    var stepX = dx > 0 ? 1 : -1, stepZ = dz > 0 ? 1 : -1;
    var tDeltaX = dx !== 0 ? Math.abs(1 / dx) : Infinity, tDeltaZ = dz !== 0 ? Math.abs(1 / dz) : Infinity;
    var tMaxX = dx !== 0 ? (dx > 0 ? cx + 1 - ox : ox - cx) * tDeltaX : Infinity;
    var tMaxZ = dz !== 0 ? (dz > 0 ? cz + 1 - oz : oz - cz) * tDeltaZ : Infinity;
    for (;;) {
      if (visit) visit(cz * MAP_W + cx);
      var t;
      if (tMaxX < tMaxZ) { t = tMaxX; tMaxX += tDeltaX; cx += stepX; }
      else { t = tMaxZ; tMaxZ += tDeltaZ; cz += stepZ; }
      if (t >= maxDist) return maxDist;
      if (isWall(cx, cz)) return t;
    }
  }
  function lineOfSight(ax, az, bx, bz) {
    var dx = bx - ax, dz = bz - az, d = Math.sqrt(dx * dx + dz * dz);
    if (d < 1e-6) return true;
    return castRay(ax, az, dx / d, dz / d, d, null) >= d;
  }

  // ---------------------------------------------------------------- renderer + paleta
  var canvas = document.getElementById('view');
  var renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: false, alpha: false, powerPreference: 'high-performance' });
  renderer.setPixelRatio(1);
  renderer.setSize(VIEW_W, VIEW_H, false);
  renderer.autoClear = false;
  renderer.setClearColor(0x000000, 1);
  var INDEX_FORMAT = renderer.capabilities.isWebGL2 ? THREE.RedFormat : THREE.LuminanceFormat;

  function fromBase64(s) {
    var bin = atob(s), out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function nearest(tex) {
    tex.magFilter = tex.minFilter = THREE.NearestFilter;
    tex.generateMipmaps = false;
    tex.unpackAlignment = 1;
    tex.needsUpdate = true;
    return tex;
  }
  // textura de índices: 1 byte por pixel (linhas invertidas: o WebGL lê de baixo para cima)
  function indexTexture(bytes, w, h) {
    var flipped = new Uint8Array(w * h);
    for (var y = 0; y < h; y++) flipped.set(bytes.subarray((h - 1 - y) * w, (h - y) * w), y * w);
    return nearest(new THREE.DataTexture(flipped, w, h, INDEX_FORMAT, THREE.UnsignedByteType));
  }

  // paleta EPAL: 256 x RGB de 5 bits -> textura 16x16 (coluna = cor, linha = conjunto)
  var pal5 = fromBase64(ASSETS.palette);
  var palRGBA = new Uint8Array(256 * 4);
  for (var p = 0; p < 256; p++) {
    for (var ch = 0; ch < 3; ch++) { var v = pal5[p * 3 + ch]; palRGBA[p * 4 + ch] = (v << 3) | (v >> 2); }
    palRGBA[p * 4 + 3] = 255;
  }
  var paletteTex = nearest(new THREE.DataTexture(palRGBA, 16, 16, THREE.RGBAFormat, THREE.UnsignedByteType));

  var textures = {};
  Object.keys(ASSETS.images).forEach(function (name) {
    var img = ASSETS.images[name];
    textures[name] = indexTexture(fromBase64(img.data), img.w, img.h);
  });

  // uniforms compartilhados: paleta, "regravação de paleta" (clarão de dano) e modo afim
  var shared = {
    tPalette: { value: paletteTex },
    uTint: { value: new THREE.Vector4(1, 0, 0, 0) },
    uAffine: { value: params.get('affine') === '1' ? 1 : 0 }
  };

  var PALETTE_GLSL = [
    'uniform sampler2D tIndex;',
    'uniform sampler2D tPalette;',
    'uniform vec4 uTint;',
    'vec3 lookup(float idx, float set) {',
    '  vec3 c = texture2D(tPalette, vec2((idx + 0.5) / 16.0, (set + 0.5) / 16.0)).rgb;',
    '  c = mix(c, uTint.rgb, uTint.a);',
    '  return floor(c * 31.0 + 0.5) / 31.0;',     // a saída continua em 15 bits
    '}'
  ].join('\n');

  // Mundo: nível de luz constante por face. uAffine = 1 interpola o UV sem correção de
  // perspectiva, como o LRMM do Geo3D faz (multiplica por w e divide de volta).
  var WORLD_VS = [
    'attribute float aLevel;',
    'uniform float uAffine;',
    'varying vec3 vUvw;',
    'varying float vLevel;',
    'void main() {',
    '  vec4 pos = projectionMatrix * modelViewMatrix * vec4(position, 1.0);',
    '  float w = mix(1.0, pos.w, uAffine);',
    '  vUvw = vec3(uv * w, w);',
    '  vLevel = aLevel;',
    '  gl_Position = pos;',
    '}'
  ].join('\n');
  var WORLD_FS = [
    PALETTE_GLSL,
    'varying vec3 vUvw;',
    'varying float vLevel;',
    'void main() {',
    '  float idx = floor(texture2D(tIndex, vUvw.xy / vUvw.z).r * 255.0 + 0.5);',
    '  gl_FragColor = vec4(lookup(idx, floor(vLevel + 0.5)), 1.0);',
    '}'
  ].join('\n');

  // Sprites: cor 0 é transparente, um conjunto de paleta por sprite (modo 3 do V9968).
  var SPRITE_VS = [
    'varying vec2 vUv;',
    'void main() {',
    '  vUv = uv;',
    '  gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);',
    '}'
  ].join('\n');
  var SPRITE_FS = [
    PALETTE_GLSL,
    'uniform float uSet;',
    'varying vec2 vUv;',
    'void main() {',
    '  float idx = floor(texture2D(tIndex, vUv).r * 255.0 + 0.5);',
    '  if (idx < 0.5) discard;',
    '  gl_FragColor = vec4(lookup(idx, uSet), 1.0);',
    '}'
  ].join('\n');

  function worldMaterial(tex) {
    return new THREE.ShaderMaterial({
      uniforms: { tIndex: { value: tex }, tPalette: shared.tPalette, uTint: shared.uTint, uAffine: shared.uAffine },
      vertexShader: WORLD_VS, fragmentShader: WORLD_FS, side: THREE.DoubleSide
    });
  }
  function spriteMaterial(name, hud) {
    return new THREE.ShaderMaterial({
      uniforms: { tIndex: { value: textures[name] }, tPalette: shared.tPalette, uTint: shared.uTint, uSet: { value: ASSETS.images[name].set } },
      vertexShader: SPRITE_VS, fragmentShader: SPRITE_FS, side: THREE.DoubleSide,
      depthTest: !hud, depthWrite: !hud
    });
  }
  function setFrame(mesh, name, dim) {
    var img = ASSETS.images[name];
    mesh.material.uniforms.tIndex.value = textures[name];
    mesh.material.uniforms.uSet.value = dim ? img.dim : img.set;
  }

  // ---------------------------------------------------------------- mundo = lista de quads
  var scene = new THREE.Scene();
  var camera = new THREE.PerspectiveCamera(2 * Math.atan((VIEW_H / 2) / FOCAL) * 180 / Math.PI, VIEW_W / VIEW_H, 0.05, 40);
  camera.rotation.order = 'YXZ';
  var HALF_FOV = Math.atan((VIEW_W / 2) / FOCAL);

  var WALL = 0, FLOOR = 1, CEIL = 2;
  var quads = [];
  var cellQuads = [];                    // célula -> quads que pertencem a ela
  var batches = {};                      // textura -> geometria com índices dinâmicos

  function addQuad(texName, cell, kind, v, nx, nz, bonus) {
    var b = batches[texName] || (batches[texName] = { pos: [], uv: [], quads: [], count: 0 });
    var q = {
      batch: b, slot: b.quads.length, kind: kind, nx: nx, nz: nz, bonus: bonus, lights: [], dist: 0,
      cx: (v[0] + v[3] + v[6] + v[9]) / 4, cz: (v[2] + v[5] + v[8] + v[11]) / 4
    };
    Array.prototype.push.apply(b.pos, v);
    b.uv.push(0, 0, 1, 0, 1, 1, 0, 1);
    b.quads.push(q);
    quads.push(q);
    (cellQuads[cell] || (cellQuads[cell] = [])).push(q);
  }

  (function buildWorld() {
    for (var z = 0; z < MAP_H; z++) for (var x = 0; x < MAP_W; x++) {
      if (isWall(x, z)) continue;
      var cell = z * MAP_W + x, lamp = MAP[z][x] === 'L';
      addQuad('floor', cell, FLOOR, [x, 0, z + 1, x + 1, 0, z + 1, x + 1, 0, z, x, 0, z], 0, 0, 0);
      addQuad(lamp ? 'ceil_light' : 'ceil', cell, CEIL, [x, 1, z, x + 1, 1, z, x + 1, 1, z + 1, x, 1, z + 1], 0, 0, lamp ? 2 : -0.4);
      // paredes vizinhas: vértices na ordem (esq-baixo, dir-baixo, dir-cima, esq-cima) vistos de dentro
      var sides = [
        [x, z - 1, [x, 0, z, x + 1, 0, z, x + 1, 1, z, x, 1, z], 0, 1],
        [x, z + 1, [x + 1, 0, z + 1, x, 0, z + 1, x, 1, z + 1, x + 1, 1, z + 1], 0, -1],
        [x - 1, z, [x, 0, z + 1, x, 0, z, x, 1, z, x, 1, z + 1], 1, 0],
        [x + 1, z, [x + 1, 0, z, x + 1, 0, z + 1, x + 1, 1, z + 1, x + 1, 1, z], -1, 0]
      ];
      for (var s = 0; s < 4; s++) {
        var wx = sides[s][0], wz = sides[s][1];
        if (!isWall(wx, wz)) continue;
        var code = (wx < 0 || wz < 0 || wx >= MAP_W || wz >= MAP_H) ? 35 : grid[wz * MAP_W + wx];
        var tex = WALL_TEX[String.fromCharCode(code)];
        // faces leste/oeste meio nível mais escuras (truque do Wolfenstein); painel técnico é emissivo
        addQuad(tex, cell, WALL, sides[s][2], sides[s][3], sides[s][4], (sides[s][3] !== 0 ? -0.6 : 0) + (tex === 'wall_tech' ? 1.2 : 0));
      }
    }

    // contribuição fixa de cada luz em cada quad (as lâmpadas não atravessam paredes)
    quads.forEach(function (q) {
      var ox = q.cx + q.nx * 0.5, oz = q.cz + q.nz * 0.5;      // centro da célula dona do quad
      lights.forEach(function (l, li) {
        var d = Math.hypot(l.x - q.cx, l.z - q.cz);
        if (d >= l.range) return;
        if (l.lamp && !lineOfSight(l.x, l.z, ox, oz)) return;
        var k = 1 - d / l.range;
        q.lights.push(li, l.power * k * k);
      });
    });

    Object.keys(batches).forEach(function (name) {
      var b = batches[name], n = b.quads.length, geo = new THREE.BufferGeometry();
      b.level = new THREE.BufferAttribute(new Float32Array(n * 4), 1);
      b.index = new THREE.BufferAttribute(new Uint16Array(n * 6), 1);
      b.level.setUsage(THREE.DynamicDrawUsage);
      b.index.setUsage(THREE.DynamicDrawUsage);
      geo.setAttribute('position', new THREE.BufferAttribute(new Float32Array(b.pos), 3));
      geo.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(b.uv), 2));
      geo.setAttribute('aLevel', b.level);
      geo.setIndex(b.index);
      b.mesh = new THREE.Mesh(geo, worldMaterial(textures[name]));
      b.mesh.frustumCulled = false;
      scene.add(b.mesh);
    });
  })();

  // ---------------------------------------------------------------- estado do jogo
  var player = { x: spawn.x, z: spawn.z, yaw: -Math.PI / 2, hp: 100, bob: 0, eye: 0.5 };
  var enemies = [], items = [], puffs = [];
  var state = 'title';                   // title | playing | paused | dead | won
  var keys = { up: false, down: false, left: false, right: false, turnL: false, turnR: false, fire: false };
  var fireCooldown = 0, muzzle = 0, recoil = 0, time = 0, messageTimer = 0;
  var stats = { faces: 0, walls: 0, flats: 0, dropped: 0, planes: 0, fps: 0 };
  var frozen = params.get('freeze') === '1';

  function billboard(name, w, h) {
    var geo = new THREE.PlaneGeometry(w, h);
    geo.translate(0, h / 2, 0);
    var mesh = new THREE.Mesh(geo, spriteMaterial(name, false));
    scene.add(mesh);
    return mesh;
  }

  function resetGame() {
    enemies.forEach(function (e) { scene.remove(e.mesh); });
    items.forEach(function (it) { scene.remove(it.mesh); });
    enemies = enemySpawns.map(function (s) {
      var t = ENEMY_TYPES[s.type];
      return { type: t, x: s.x, z: s.z, hp: t.hp, state: 'idle', t: 0, anim: Math.random(), frame: '', dim: null,
               struck: false, stuck: 0, detour: 0, mesh: billboard(t.name + '_walk1', 0.75, 1.0) };
    });
    items = itemSpawns.map(function (s) {
      return { x: s.x, z: s.z, taken: false, mesh: billboard('medkit', 0.4, 0.4) };
    });
    player.x = spawn.x; player.z = spawn.z; player.yaw = -Math.PI / 2; player.hp = 100; player.bob = 0; player.eye = 0.5;
    if (params.get('pose')) {
      var pose = params.get('pose').split(',').map(Number);
      player.x = pose[0]; player.z = pose[1]; player.yaw = (pose[2] || 0) * Math.PI / 180;
    }
    fireCooldown = muzzle = recoil = 0;
    shared.uTint.value.set(1, 0, 0, 0);
    flowCell = -1;
    updateHud(true);
    setMessage('MSX DOOM', 0);
  }

  // ---------------------------------------------------------------- visibilidade + lista de faces
  var stamp = new Uint32Array(MAP_W * MAP_H), frameId = 0, visCells = [], faceList = [];

  function markCell(c) { if (stamp[c] !== frameId) { stamp[c] = frameId; visCells.push(c); } }

  // O Z80 faria o mesmo: raios na grade marcam as células à vista e só os quads delas
  // seguem para o Geo3D (que não tem z-buffer nem recorte para esconder o resto).
  function computeVisibility() {
    frameId++;
    visCells.length = 0;
    var pcx = Math.floor(player.x), pcz = Math.floor(player.z);
    for (var dz = -1; dz <= 1; dz++) for (var dx = -1; dx <= 1; dx++) {
      if (!isWall(pcx + dx, pcz + dz)) markCell((pcz + dz) * MAP_W + pcx + dx);
    }
    var half = HALF_FOV + 0.12;
    for (var i = 0; i < NUM_RAYS; i++) {
      var a = player.yaw + half - (i / (NUM_RAYS - 1)) * 2 * half;
      castRay(player.x, player.z, -Math.sin(a), -Math.cos(a), DRAW_DIST, markCell);
    }
  }

  function lightAt(x, z, dist, staticLight) {
    var lv = AMBIENT + staticLight + PLAYER_LIGHT * Math.max(0, 1 - dist / PLAYER_LIGHT_RANGE);
    if (muzzle > 0) lv += 3 * Math.max(0, 1 - dist / 5);                       // clarão do tiro
    if (dist > DRAW_DIST - 2.5) lv -= (dist - (DRAW_DIST - 2.5)) * 2.4;          // some no escuro
    return lv;
  }

  function buildFaces() {
    var name, i, q;
    for (name in batches) batches[name].count = 0;
    faceList.length = 0;
    for (i = 0; i < visCells.length; i++) {
      var list = cellQuads[visCells[i]];
      for (var j = 0; j < list.length; j++) {
        q = list[j];
        // descarte de face oculta, como o Geo3D faz
        if (q.kind === WALL && (player.x - q.cx) * q.nx + (player.z - q.cz) * q.nz <= 0) continue;
        q.dist = Math.hypot(q.cx - player.x, q.cz - player.z);
        faceList.push(q);
      }
    }
    stats.dropped = 0;
    if (faceList.length > MAX_FACES) {                    // estourou o RUN: as mais distantes caem
      faceList.sort(function (a, b) { return a.dist - b.dist; });
      stats.dropped = faceList.length - MAX_FACES;
      faceList.length = MAX_FACES;
    }
    stats.walls = stats.flats = 0;
    for (i = 0; i < faceList.length; i++) {
      q = faceList[i];
      var st = q.bonus;
      for (var k = 0; k < q.lights.length; k += 2) st += q.lights[k + 1] * lights[q.lights[k]].now;
      var level = Math.max(0, Math.min(MAX_LEVEL, Math.round(lightAt(q.cx, q.cz, q.dist, st))));
      var b = q.batch, base = q.slot * 4, lv = b.level.array, ix = b.index.array, o = b.count * 6;
      lv[base] = lv[base + 1] = lv[base + 2] = lv[base + 3] = level;
      ix[o] = base; ix[o + 1] = base + 1; ix[o + 2] = base + 2; ix[o + 3] = base; ix[o + 4] = base + 2; ix[o + 5] = base + 3;
      b.count++;
      if (q.kind === WALL) stats.walls++; else stats.flats++;
    }
    stats.faces = faceList.length;
    for (name in batches) {
      var bt = batches[name];
      bt.mesh.geometry.setDrawRange(0, bt.count * 6);
      bt.mesh.visible = bt.count > 0;
      bt.level.needsUpdate = true;
      bt.index.needsUpdate = true;
    }
  }

  // luz no ponto (x, z) para escolher o conjunto de paleta claro/escuro dos sprites
  function spriteIsDim(x, z) {
    var st = 0;
    for (var i = 0; i < lights.length; i++) {
      var l = lights[i], d = Math.hypot(l.x - x, l.z - z);
      if (d < l.range) { var k = 1 - d / l.range; st += l.power * k * k * l.now; }
    }
    return lightAt(x, z, Math.hypot(x - player.x, z - player.z), st) < 2.5;
  }
  function cellSeen(x, z) {
    var cx = Math.floor(x), cz = Math.floor(z);
    for (var dz = -1; dz <= 1; dz++) for (var dx = -1; dx <= 1; dx++) {
      var nx = cx + dx, nz = cz + dz;
      if (nx >= 0 && nz >= 0 && nx < MAP_W && nz < MAP_H && stamp[nz * MAP_W + nx] === frameId) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- inimigos
  var flow = new Int16Array(MAP_W * MAP_H), flowCell = -1, flowQueue = new Int32Array(MAP_W * MAP_H);

  // distância em passos de cada célula até o jogador (os inimigos descem esse campo)
  function updateFlow() {
    var pc = Math.floor(player.z) * MAP_W + Math.floor(player.x);
    if (pc === flowCell) return;
    flowCell = pc;
    flow.fill(-1);
    var head = 0, tail = 0;
    flow[pc] = 0; flowQueue[tail++] = pc;
    while (head < tail) {
      var c = flowQueue[head++], cx = c % MAP_W, cz = (c / MAP_W) | 0;
      var nb = [cx + 1, cz, cx - 1, cz, cx, cz + 1, cx, cz - 1];
      for (var i = 0; i < 8; i += 2) {
        if (isWall(nb[i], nb[i + 1])) continue;
        var n = nb[i + 1] * MAP_W + nb[i];
        if (flow[n] < 0) { flow[n] = flow[c] + 1; flowQueue[tail++] = n; }
      }
    }
  }

  function alertEnemy(e) {
    if (e.state !== 'idle') return;
    e.state = 'chase';
    sfx.growl(e.type === ENEMY_TYPES.f ? 90 : 62);
  }

  function hurtEnemy(e, dmg) {
    e.hp -= dmg;
    if (e.hp <= 0) {
      e.state = 'dying'; e.t = 0;
      sfx.death();
      var left = enemiesLeft();
      setMessage(left === 0 ? 'SETOR LIMPO' : 'ABATIDO', 1.2);
      updateHud();
      if (left === 0) endGame('won');
    } else {
      e.state = 'pain'; e.t = 0;
      sfx.pain();
    }
  }

  function enemiesLeft() {
    var n = 0;
    for (var i = 0; i < enemies.length; i++) if (enemies[i].hp > 0) n++;
    return n;
  }

  function updateEnemy(e, dt) {
    var T = e.type, dx = player.x - e.x, dz = player.z - e.z, dist = Math.hypot(dx, dz), frame = T.name + '_walk1';
    e.t += dt;
    if (e.state === 'dead') frame = T.name + '_dead';
    else if (e.state === 'dying') {
      frame = T.name + '_dying';
      if (e.t > 0.32) e.state = 'dead';
    } else if (e.state === 'pain') {
      frame = T.name + '_pain';
      if (e.t > 0.22) { e.state = 'chase'; e.t = 0; }
    } else if (e.state === 'idle') {
      if (dist < 9 && lineOfSight(e.x, e.z, player.x, player.z)) alertEnemy(e);
    } else if (e.state === 'attack') {
      frame = T.name + '_attack';
      if (!e.struck && e.t > 0.26) {
        e.struck = true;
        if (dist < T.reach + 0.3) hurtPlayer(T.damage);
      }
      if (e.t > 0.6) { e.state = 'chase'; e.t = 0; }
    } else {                                              // chase
      if (dist < T.reach) { e.state = 'attack'; e.t = 0; e.struck = false; }
      else {
        var tx = player.x, tz = player.z;
        e.detour -= dt;
        if (e.detour > 0 || !lineOfSight(e.x, e.z, player.x, player.z)) {
          // sem visada (ou preso numa quina): vai para a célula vizinha mais perto do jogador
          var cx = Math.floor(e.x), cz = Math.floor(e.z), best = flow[cz * MAP_W + cx];
          var nb = [cx + 1, cz, cx - 1, cz, cx, cz + 1, cx, cz - 1];
          for (var i = 0; i < 8; i += 2) {
            if (isWall(nb[i], nb[i + 1])) continue;
            var f = flow[nb[i + 1] * MAP_W + nb[i]];
            if (f >= 0 && (best < 0 || f < best)) { best = f; tx = nb[i] + 0.5; tz = nb[i + 1] + 0.5; }
          }
        }
        var mx = tx - e.x, mz = tz - e.z, ml = Math.hypot(mx, mz) || 1, step = T.speed * dt;
        var bx = e.x, bz = e.z;
        moveCircle(e, mx / ml * step, mz / ml * step, T.radius);
        if (Math.hypot(e.x - bx, e.z - bz) < step * 0.3) { e.stuck += dt; if (e.stuck > 0.25) { e.detour = 0.8; e.stuck = 0; } }
        else e.stuck = 0;
        e.anim += dt * T.speed * 2.2;
        frame = T.name + ((e.anim | 0) % 2 ? '_walk2' : '_walk1');
      }
    }
    var dim = e.hp > 0 && spriteIsDim(e.x, e.z);
    if (frame !== e.frame || dim !== e.dim) { e.frame = frame; e.dim = dim; setFrame(e.mesh, frame, dim); }
  }

  function separateEnemies() {
    for (var i = 0; i < enemies.length; i++) {
      var a = enemies[i];
      if (a.hp <= 0) continue;
      for (var j = i + 1; j < enemies.length; j++) {
        var b = enemies[j];
        if (b.hp <= 0) continue;
        var dx = b.x - a.x, dz = b.z - a.z, d = Math.hypot(dx, dz);
        if (d >= 0.55 || d < 1e-4) continue;
        var push = (0.55 - d) / 2;
        moveCircle(a, -dx / d * push, -dz / d * push, a.type.radius);
        moveCircle(b, dx / d * push, dz / d * push, b.type.radius);
      }
    }
  }

  // ---------------------------------------------------------------- jogador
  function hurtPlayer(dmg) {
    if (state !== 'playing' || params.get('god') === '1') return;
    player.hp = Math.max(0, player.hp - dmg);
    shared.uTint.value.set(1, 0, 0, 0.55);
    sfx.hurt();
    updateHud();
    if (player.hp <= 0) endGame('dead');
  }

  function fire() {
    if (fireCooldown > 0 || state !== 'playing') return;
    fireCooldown = FIRE_DELAY; muzzle = 0.07; recoil = 1;
    sfx.shot();
    var dx = -Math.sin(player.yaw), dz = -Math.cos(player.yaw);
    var wallDist = castRay(player.x, player.z, dx, dz, 40, null);
    var hit = null, hitAt = wallDist;
    for (var i = 0; i < enemies.length; i++) {
      var e = enemies[i];
      if (e.hp <= 0) continue;
      var vx = e.x - player.x, vz = e.z - player.z, along = vx * dx + vz * dz;
      if (along < 0.1 || along > hitAt) continue;
      if (Math.abs(vx * dz - vz * dx) < 0.3) { hit = e; hitAt = along; }
    }
    if (hit) hurtEnemy(hit, 10 + ((Math.random() * 6) | 0));
    else spawnPuff(player.x + dx * (wallDist - 0.06), player.z + dz * (wallDist - 0.06));
    // o tiro acorda quem está por perto (distância em passos pelo mapa)
    for (i = 0; i < enemies.length; i++) {
      var f = flow[Math.floor(enemies[i].z) * MAP_W + Math.floor(enemies[i].x)];
      if (f >= 0 && f <= 9) alertEnemy(enemies[i]);
    }
  }

  function spawnPuff(x, z) {
    var pf = puffs.length < 3 ? null : puffs.shift();
    if (!pf) { pf = { mesh: billboard('muzzle_flash', 0.22, 0.22), t: 0 }; }
    pf.t = 0.09;
    pf.mesh.position.set(x, 0.39, z);
    pf.mesh.visible = true;
    puffs.push(pf);
  }

  function updatePlayer(dt) {
    if (keys.turnL) player.yaw += TURN_SPEED * dt;
    if (keys.turnR) player.yaw -= TURN_SPEED * dt;
    var f = (keys.up ? 1 : 0) - (keys.down ? 1 : 0), s = (keys.right ? 1 : 0) - (keys.left ? 1 : 0);
    if (f || s) {
      var n = PLAYER_SPEED * dt / Math.hypot(f, s);
      var fx = -Math.sin(player.yaw), fz = -Math.cos(player.yaw), rx = Math.cos(player.yaw), rz = -Math.sin(player.yaw);
      var ox = player.x, oz = player.z;
      moveCircle(player, (fx * f + rx * s) * n, (fz * f + rz * s) * n, PLAYER_RADIUS);
      // inimigos vivos são sólidos
      for (var i = 0; i < enemies.length; i++) {
        var e = enemies[i];
        if (e.hp > 0 && Math.hypot(e.x - player.x, e.z - player.z) < 0.45) { player.x = ox; player.z = oz; break; }
      }
      player.bob += dt * 9;
    }
    for (var k = 0; k < items.length; k++) {
      var it = items[k];
      if (!it.taken && player.hp < 100 && Math.hypot(it.x - player.x, it.z - player.z) < 0.5) {
        it.taken = true; it.mesh.visible = false;
        player.hp = Math.min(100, player.hp + MEDKIT_HEAL);
        shared.uTint.value.set(0.35, 1, 0.35, 0.3);
        sfx.pickup();
        setMessage('+' + MEDKIT_HEAL + ' VIDA', 1.5);
        updateHud();
      }
    }
    if (keys.fire) fire();
  }

  function update(dt) {
    time += dt;
    fireCooldown = Math.max(0, fireCooldown - dt);
    muzzle = Math.max(0, muzzle - dt);
    recoil = Math.max(0, recoil - dt * 7);
    shared.uTint.value.w = Math.max(state === 'dead' ? 0.35 : 0, shared.uTint.value.w - dt * 1.6);
    if (messageTimer > 0 && (messageTimer -= dt) <= 0) setMessage('MSX DOOM', 0);

    // lâmpadas com defeito: intensidade muda em degraus, não suavemente
    for (var i = 0; i < lights.length; i++) {
      var l = lights[i];
      if (l.flicker) l.now = (Math.sin(time * 23 + i * 7) + Math.sin(time * 61 + i * 3)) > 0.9 ? 0.25 : 1;
    }
    for (i = puffs.length - 1; i >= 0; i--) {
      if ((puffs[i].t -= dt) <= 0) puffs[i].mesh.visible = false;
    }
    if (state === 'dead') { player.eye = Math.max(0.14, player.eye - dt * 0.9); return; }
    if (state !== 'playing') return;

    updatePlayer(dt);
    updateFlow();
    if (!frozen) {
      for (i = 0; i < enemies.length; i++) updateEnemy(enemies[i], dt);
      separateEnemies();
    }
  }

  // ---------------------------------------------------------------- HUD dentro da janela 3D
  var hudScene = new THREE.Scene();
  var hudCamera = new THREE.OrthographicCamera(0, VIEW_W, VIEW_H, 0, -1, 1);

  function hudSprite(material, w, h, order) {
    var mesh = new THREE.Mesh(new THREE.PlaneGeometry(w, h), material);
    mesh.renderOrder = order;
    hudScene.add(mesh);
    return mesh;
  }
  var flashMesh = hudSprite(spriteMaterial('muzzle_flash', true), 32, 32, 0);
  var weaponMesh = hudSprite(spriteMaterial('pistol', true), 64, 128, 1);      // 4 planos de 16x128

  // mira: sprite 16x16 com as cores do conjunto 13 (paleta TMS9918: 15 = branco, 8 = vermelho)
  var crossMesh = (function () {
    var px = new Uint8Array(16 * 16);
    function dot(x, y, c) { px[y * 16 + x] = c; }
    for (var i = 2; i <= 4; i++) { dot(8 - i, 8, 15); dot(8 + i, 8, 15); dot(8, 8 - i, 15); dot(8, 8 + i, 15); }
    dot(8, 8, 8);
    var mat = spriteMaterial('muzzle_flash', true);
    mat.uniforms.tIndex = { value: indexTexture(px, 16, 16) };
    mat.uniforms.uSet = { value: 13 };
    var mesh = hudSprite(mat, 16, 16, 2);
    mesh.position.set(VIEW_W / 2, VIEW_H / 2, 0);      // o pixel central cai em (128, 90)
    return mesh;
  })();

  function updateHudSprites() {
    var moving = keys.up || keys.down || keys.left || keys.right;
    var bobX = moving ? Math.round(Math.sin(player.bob * 0.5) * 3) : 0;
    var bobY = moving ? Math.round(Math.abs(Math.cos(player.bob * 0.5)) * 3) : 0;
    var drop = state === 'dead' ? 70 : 0;
    var y = 4 - bobY - Math.round(recoil * 7) - drop;           // centro do sprite de 128 px
    weaponMesh.position.set(VIEW_W / 2 + bobX, y, 0);
    flashMesh.visible = muzzle > 0;
    flashMesh.position.set(VIEW_W / 2 + bobX, y + 66, 0);
    crossMesh.visible = state === 'playing';
  }

  // ---------------------------------------------------------------- som (ondas quadradas + ruído, estilo PSG)
  var sfx = (function () {
    var ctx = null, master = null, noise = null, muted = false;
    function init() {
      if (ctx) { if (ctx.state === 'suspended') ctx.resume(); return; }
      var AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      ctx = new AC();
      master = ctx.createGain(); master.gain.value = 0.22; master.connect(ctx.destination);
      noise = ctx.createBuffer(1, ctx.sampleRate, ctx.sampleRate);
      var d = noise.getChannelData(0);
      for (var i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    }
    function env(gain, peak, dur) {
      var t = ctx.currentTime;
      gain.gain.setValueAtTime(peak, t);
      gain.gain.exponentialRampToValueAtTime(0.001, t + dur);
    }
    function tone(f0, f1, dur, peak, delay) {
      if (!ctx || muted) return;
      var t = ctx.currentTime + (delay || 0), o = ctx.createOscillator(), g = ctx.createGain();
      o.type = 'square';
      o.frequency.setValueAtTime(f0, t);
      o.frequency.exponentialRampToValueAtTime(Math.max(20, f1), t + dur);
      g.gain.setValueAtTime(peak, t);
      g.gain.exponentialRampToValueAtTime(0.001, t + dur);
      o.connect(g); g.connect(master);
      o.start(t); o.stop(t + dur + 0.02);
    }
    function burst(dur, peak, f0, f1) {
      if (!ctx || muted) return;
      var src = ctx.createBufferSource(), flt = ctx.createBiquadFilter(), g = ctx.createGain(), t = ctx.currentTime;
      src.buffer = noise;
      flt.type = 'lowpass';
      flt.frequency.setValueAtTime(f0, t);
      flt.frequency.exponentialRampToValueAtTime(f1, t + dur);
      env(g, peak, dur);
      src.connect(flt); flt.connect(g); g.connect(master);
      src.start(t); src.stop(t + dur + 0.02);
    }
    return {
      init: init,
      toggle: function () { muted = !muted; return muted; },
      shot: function () { burst(0.22, 1.0, 3200, 220); tone(170, 42, 0.13, 0.6); },
      pain: function () { tone(260, 120, 0.12, 0.35); },
      death: function () { tone(190, 35, 0.5, 0.45); burst(0.35, 0.35, 900, 120); },
      growl: function (f) { tone(f, f * 0.6, 0.35, 0.3); tone(f * 1.5, f * 0.8, 0.3, 0.15, 0.05); },
      hurt: function () { tone(110, 70, 0.2, 0.5); burst(0.12, 0.4, 1200, 300); },
      pickup: function () { tone(660, 660, 0.07, 0.3); tone(880, 880, 0.07, 0.3, 0.07); tone(1320, 1320, 0.12, 0.3, 0.14); }
    };
  })();

  // ---------------------------------------------------------------- HUD em HTML + telas
  var el = {
    stage: document.getElementById('stage'), overlay: document.getElementById('overlay'),
    title: document.getElementById('overlay-title'), sub: document.getElementById('overlay-sub'),
    help: document.getElementById('overlay-help'), action: document.getElementById('overlay-action'),
    hp: document.getElementById('hp-value'), hpBar: document.getElementById('hp-bar'),
    enemy: document.getElementById('enemy-value'), kills: document.getElementById('kills-label'),
    message: document.getElementById('message'), debug: document.getElementById('debug')
  };
  var hudCache = { hp: -1, left: -1 };

  function updateHud(force) {
    var left = enemiesLeft();
    if (!force && hudCache.hp === player.hp && hudCache.left === left) return;
    hudCache.hp = player.hp; hudCache.left = left;
    el.hp.textContent = player.hp + '%';
    el.hp.classList.toggle('low', player.hp <= 25);
    el.hpBar.style.width = player.hp + '%';
    el.enemy.textContent = left;
    el.kills.textContent = 'ABATES ' + (enemies.length - left) + '/' + enemies.length;
  }
  function setMessage(text, seconds) { el.message.textContent = text; messageTimer = seconds; }

  function showOverlay(title, sub, action, help) {
    el.title.textContent = title; el.sub.textContent = sub; el.action.textContent = action;
    el.help.hidden = !help;
    el.overlay.hidden = false;
  }
  function endGame(result) {
    state = result;
    keys.fire = false;
    if (document.pointerLockElement) document.exitPointerLock();
    if (result === 'won') showOverlay('SETOR LIMPO', 'TODOS OS INIMIGOS ABATIDOS · VIDA ' + player.hp + '%', 'CLIQUE OU ENTER PARA JOGAR DE NOVO', false);
    else showOverlay('VOCÊ MORREU', 'RESTAM ' + enemiesLeft() + ' INIMIGOS', 'CLIQUE OU ENTER PARA TENTAR DE NOVO', false);
  }

  function lockPointer() {
    if (canvas.requestPointerLock) {
      var req = canvas.requestPointerLock();
      if (req && req.catch) req.catch(function () {});
    }
  }
  function startOrResume() {
    sfx.init();
    if (state === 'dead' || state === 'won') resetGame();
    state = 'playing';
    el.overlay.hidden = true;
    lockPointer();
  }
  el.overlay.addEventListener('click', startOrResume);
  canvas.addEventListener('click', function () { if (state === 'playing' && !document.pointerLockElement) lockPointer(); });

  document.addEventListener('pointerlockchange', function () {
    if (!document.pointerLockElement && state === 'playing' && params.get('autostart') !== '1') {
      state = 'paused';
      for (var k in keys) keys[k] = false;
      showOverlay('PAUSA', 'O MOUSE FOI LIBERADO', 'CLIQUE PARA CONTINUAR', true);
    }
  });
  document.addEventListener('mousemove', function (e) {
    if (state === 'playing' && document.pointerLockElement === canvas) player.yaw -= e.movementX * MOUSE_SENS;
  });
  document.addEventListener('mousedown', function (e) {
    if (e.button === 0 && state === 'playing' && document.pointerLockElement === canvas) keys.fire = true;
  });
  document.addEventListener('mouseup', function (e) { if (e.button === 0) keys.fire = false; });

  var KEYMAP = {
    ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right',     // cursores do MSX
    KeyW: 'up', KeyS: 'down', KeyA: 'left', KeyD: 'right',
    KeyQ: 'turnL', KeyE: 'turnR', Space: 'fire'                                    // ESPAÇO = gatilho A
  };
  document.addEventListener('keydown', function (e) {
    var k = KEYMAP[e.code];
    if (k) { if (state === 'playing') keys[k] = true; e.preventDefault(); return; }
    if (e.code === 'F1') { el.debug.hidden = !el.debug.hidden; e.preventDefault(); }
    else if (e.code === 'KeyT') shared.uAffine.value = shared.uAffine.value ? 0 : 1;
    else if (e.code === 'KeyM') setMessage(sfx.toggle() ? 'SOM DESLIGADO' : 'SOM LIGADO', 1.2);
    else if (e.code === 'Enter' && state !== 'playing') startOrResume();
  });
  document.addEventListener('keyup', function (e) { var k = KEYMAP[e.code]; if (k) keys[k] = false; });
  window.addEventListener('blur', function () { for (var k in keys) keys[k] = false; });

  function resize() {
    var s = Math.max(1, Math.floor(Math.min(window.innerWidth / 268, window.innerHeight / 224)));
    document.documentElement.style.setProperty('--s', s);
  }
  window.addEventListener('resize', resize);
  resize();

  // ---------------------------------------------------------------- quadro
  // Com a câmera exatamente sobre uma divisa de células e olhando reto, os vértices dessa
  // divisa ficam com w = 0 e a interpolação degenera; meio milésimo de célula resolve.
  function offGrid(v) {
    var f = v - Math.floor(v);
    return f < 5e-4 ? v + 5e-4 : (f > 1 - 5e-4 ? v - 5e-4 : v);
  }

  function render() {
    camera.position.set(offGrid(player.x), player.eye + (state === 'playing' ? Math.sin(player.bob) * 0.012 : 0), offGrid(player.z));
    camera.rotation.set(0, player.yaw, state === 'dead' ? 0.35 * (0.5 - player.eye) / 0.36 : 0);
    computeVisibility();
    buildFaces();

    stats.planes = 4 + (muzzle > 0 ? 2 : 0) + 1;         // arma + clarão + mira
    var i;
    for (i = 0; i < enemies.length; i++) {
      var e = enemies[i];
      e.mesh.visible = cellSeen(e.x, e.z);
      e.mesh.position.set(e.x, 0, e.z);
      e.mesh.rotation.y = player.yaw;                    // sempre de frente para a câmera
      if (e.mesh.visible) stats.planes += 3;
    }
    for (i = 0; i < items.length; i++) {
      var it = items[i];
      it.mesh.visible = !it.taken && cellSeen(it.x, it.z);
      it.mesh.position.set(it.x, 0, it.z);
      it.mesh.rotation.y = player.yaw;
      if (it.mesh.visible) stats.planes += 2;
    }
    for (i = 0; i < puffs.length; i++) puffs[i].mesh.rotation.y = player.yaw;
    updateHudSprites();

    renderer.clear();
    renderer.render(scene, camera);
    renderer.render(hudScene, hudCamera);

    if (!el.debug.hidden) {
      el.debug.textContent =
        'GEO3D faces ' + stats.faces + '/' + MAX_FACES + (stats.dropped ? '  (-' + stats.dropped + ' cortadas)' : '') + '\n' +
        '  paredes ' + stats.walls + '  piso/teto ' + stats.flats + '\n' +
        'SPRITE planos ' + stats.planes + '/' + SPRITE_PLANES + '\n' +
        'textura ' + (shared.uAffine.value ? 'AFIM (Geo3D)' : 'perspectiva') + '  [T]\n' +
        'F=' + FOCAL + '  ' + VIEW_W + 'x' + VIEW_H + '  ' + stats.fps + ' fps';
    }
  }

  var last = 0, fpsCount = 0, fpsTime = 0;
  function loop(now) {
    var dt = Math.min(0.05, (now - last) / 1000 || 0);
    last = now;
    fpsCount++; fpsTime += dt;
    if (fpsTime >= 0.5) { stats.fps = Math.round(fpsCount / fpsTime); fpsCount = 0; fpsTime = 0; }
    update(dt);
    render();
    window.requestAnimationFrame(loop);
  }

  resetGame();
  if (params.get('debug') === '1') el.debug.hidden = false;
  if (params.get('autostart') === '1') { state = 'playing'; el.overlay.hidden = true; }

  // API para testes e depuração no console
  window.MSXDOOM = {
    player: player, keys: keys, stats: stats, lights: lights, quads: quads,
    get enemies() { return enemies; }, get items() { return items; }, get state() { return state; },
    update: update, render: render, fire: fire, lineOfSight: lineOfSight, isWall: isWall,
    map: MAP, flow: flow, maxFaces: MAX_FACES,
    restart: function () { resetGame(); state = 'playing'; el.overlay.hidden = true; },
    // faces que iriam para o Geo3D na pose atual, antes do corte em MAX_FACES (não desenha)
    countFaces: function () { computeVisibility(); buildFaces(); return stats.faces + stats.dropped; }
  };

  // index.html?selftest=1 roda tools/selftest.js (bot que joga a fase e mede o orçamento de faces)
  if (params.get('selftest') === '1') {
    var script = document.createElement('script');
    script.src = 'tools/selftest.js';
    document.body.appendChild(script);
    return;
  }
  if (params.get('manual') !== '1') window.requestAnimationFrame(loop);
})();
