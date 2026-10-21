/* Autoteste do MSX DOOM. Abra index.html?selftest=1 — o resultado aparece na tela
 * (elemento #selftest) e no título da aba ("SELFTEST PASS" / "SELFTEST FAIL").
 * Não usa requestAnimationFrame: avança a simulação em passos fixos de 1/30 s.
 */
(function () {
  'use strict';

  var G = window.MSXDOOM, A = window.MSXDOOM_ASSETS;
  var W = G.map[0].length, H = G.map.length, DT = 1 / 30;
  var lines = [], fails = 0;

  function check(name, ok, detail) {
    lines.push((ok ? 'PASS  ' : 'FAIL  ') + name + (detail ? '  ->  ' + detail : ''));
    if (!ok) fails++;
  }
  function cellOf(o) { return Math.floor(o.z) * W + Math.floor(o.x); }
  function clearKeys() { for (var k in G.keys) G.keys[k] = false; }

  // distância em passos de todas as células até (x, z)
  function bfs(x, z) {
    var dist = new Int16Array(W * H).fill(-1), queue = [Math.floor(z) * W + Math.floor(x)], head = 0;
    dist[queue[0]] = 0;
    while (head < queue.length) {
      var c = queue[head++], cx = c % W, cz = (c / W) | 0;
      [[1, 0], [-1, 0], [0, 1], [0, -1]].forEach(function (d) {
        var nx = cx + d[0], nz = cz + d[1];
        if (G.isWall(nx, nz) || dist[nz * W + nx] >= 0) return;
        dist[nz * W + nx] = dist[c] + 1;
        queue.push(nz * W + nx);
      });
    }
    return dist;
  }
  function face(x, z) { G.player.yaw = Math.atan2(-(x - G.player.x), -(z - G.player.z)); }

  try {
    // ------------------------------------------------------------ assets
    var names = Object.keys(A.images), badSize = [], badIndex = [];
    names.forEach(function (n) {
      var img = A.images[n], bytes = atob(img.data);
      if (bytes.length !== img.w * img.h) badSize.push(n);
      for (var i = 0; i < bytes.length; i++) if (bytes.charCodeAt(i) > 15) { badIndex.push(n); break; }
      if (img.kind === 'sprite' && img.w % 16 !== 0) badSize.push(n + ' (largura nao multipla de 16)');
    });
    check('assets: 21 imagens indexadas', names.length === 21, names.length + ' imagens');
    check('assets: tamanho dos dados = w*h', badSize.length === 0, badSize.join(', '));
    check('assets: todos os indices em 0..15 (16 cores por conjunto)', badIndex.length === 0, badIndex.join(', '));
    var pal = atob(A.palette), over = 0;
    for (var i = 0; i < pal.length; i++) if (pal.charCodeAt(i) > 31) over++;
    check('paleta: 256 entradas RGB de 5 bits', pal.length === 768 && over === 0, pal.length + ' bytes');

    // ------------------------------------------------------------ mapa
    G.restart();
    var fromSpawn = bfs(G.player.x, G.player.z), unreachable = 0;
    G.enemies.concat(G.items).forEach(function (o) { if (fromSpawn[cellOf(o)] < 0) unreachable++; });
    check('mapa: inimigos e itens alcancaveis a partir do jogador', unreachable === 0,
      G.enemies.length + ' inimigos, ' + G.items.length + ' kits');

    // ------------------------------------------------------------ orçamento de faces do Geo3D
    // pior caso: jogador no centro de cada célula livre, olhando em 16 direções
    var worst = 0, worstAt = '', total = 0, samples = 0, over255 = 0;
    for (var z = 0; z < H; z++) for (var x = 0; x < W; x++) {
      if (G.isWall(x, z)) continue;
      for (var a = 0; a < 16; a++) {
        G.player.x = x + 0.5; G.player.z = z + 0.5; G.player.yaw = a * Math.PI / 8;
        var n = G.countFaces();
        total += n; samples++;
        if (n > G.maxFaces) over255++;
        if (n > worst) { worst = n; worstAt = '(' + x + ',' + z + ') ' + Math.round(a * 22.5) + ' graus'; }
      }
    }
    check('geo3d: nenhuma pose passa de ' + G.maxFaces + ' faces por RUN', over255 === 0,
      'pior caso ' + worst + ' em ' + worstAt + ', media ' + Math.round(total / samples) + ', ' + samples + ' poses');

    // ------------------------------------------------------------ render
    G.restart();
    G.render();
    check('render: um quadro desenhado sem erro', G.stats.faces > 0, G.stats.faces + ' faces, ' + G.stats.planes + ' planos de sprite');

    // ------------------------------------------------------------ kit médico
    G.restart();
    G.player.hp = 50; G.player.x = G.items[0].x; G.player.z = G.items[0].z;
    G.update(DT);
    check('kit medico: +25 de vida e some do mapa', G.player.hp === 75 && G.items[0].taken, 'vida ' + G.player.hp);

    // ------------------------------------------------------------ dano e morte
    G.restart();
    var foe = G.enemies[0];
    G.player.x = foe.x; G.player.z = foe.z + 0.8;
    for (var s = 0; s < 900 && G.state === 'playing'; s++) G.update(DT);
    check('inimigo ataca corpo a corpo ate o jogador morrer', G.state === 'dead' && G.player.hp === 0,
      'estado ' + G.state + ' apos ' + (s * DT).toFixed(1) + ' s');

    // ------------------------------------------------------------ bot joga a fase inteira
    G.restart();
    var steps = 0, shots = 0, minHp = 100, maxFaces = 0, stuckFor = 0, lastCell = -1;
    while (G.state === 'playing' && steps < 30 * 240) {
      var p = G.player, target = null, best = 1e9;
      G.enemies.forEach(function (e) {
        var f = G.flow[cellOf(e)];
        if (e.hp > 0 && f >= 0 && f < best) { best = f; target = e; }
      });
      clearKeys();
      if (target) {
        var d = Math.hypot(target.x - p.x, target.z - p.z);
        if (d < 7 && G.lineOfSight(p.x, p.z, target.x, target.z)) {
          face(target.x, target.z);
          G.keys.fire = true;
          G.keys.down = d < 2.2;                       // recua atirando quando chegam perto
          shots++;
        } else {
          var toTarget = bfs(target.x, target.z), pcx = Math.floor(p.x), pcz = Math.floor(p.z);
          var next = null, nd = toTarget[pcz * W + pcx];
          [[1, 0], [-1, 0], [0, 1], [0, -1]].forEach(function (dd) {
            var nx = pcx + dd[0], nz = pcz + dd[1];
            if (!G.isWall(nx, nz) && toTarget[nz * W + nx] >= 0 && toTarget[nz * W + nx] < nd) { nd = toTarget[nz * W + nx]; next = [nx + 0.5, nz + 0.5]; }
          });
          if (next) { face(next[0], next[1]); G.keys.up = true; }
        }
      }
      G.update(DT);
      steps++;
      minHp = Math.min(minHp, p.hp);
      if (steps % 15 === 0) { G.render(); maxFaces = Math.max(maxFaces, G.stats.faces); }
      var c = cellOf(p);
      stuckFor = c === lastCell && !G.keys.fire ? stuckFor + 1 : 0;
      lastCell = c;
      if (stuckFor > 30 * 20) break;                   // 20 s parado sem atirar = travou
    }
    var dead = G.enemies.filter(function (e) { return e.state === 'dead' || e.state === 'dying'; }).length;
    check('bot limpa a fase (pistola, sem trapaca)', G.state === 'won',
      'estado ' + G.state + ', ' + dead + '/' + G.enemies.length + ' abates em ' + (steps * DT).toFixed(0) +
      ' s de jogo, vida final ' + G.player.hp + '% (minima ' + minHp + '%), max ' + maxFaces + ' faces');
    clearKeys();
  } catch (err) {
    check('excecao durante o teste', false, String(err && err.stack || err));
  }

  var pre = document.createElement('pre');
  pre.id = 'selftest';
  pre.style.cssText = 'position:fixed;left:8px;top:8px;margin:0;padding:8px 12px;font:13px/1.5 Consolas,monospace;' +
    'background:rgba(0,0,0,.92);color:' + (fails ? '#ff7978' : '#5edc78') + ';z-index:10;text-transform:none;white-space:pre-wrap;max-width:96vw';
  pre.textContent = 'SELFTEST ' + (fails ? 'FAIL (' + fails + ')' : 'PASS') + '\n' + lines.join('\n');
  document.body.appendChild(pre);
  document.title = 'SELFTEST ' + (fails ? 'FAIL' : 'PASS');
  G.render();
})();
