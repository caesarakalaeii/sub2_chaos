// OBS overlay client. Subscribes to the vote-engine SSE stream and renders the
// current round: options, live tallies, and a smooth countdown.

const el = {
  app: document.getElementById("app"),
  status: document.getElementById("status"),
  countdown: document.getElementById("countdown"),
  options: document.getElementById("options"),
  round: document.getElementById("round"),
  total: document.getElementById("total"),
};

let state = null;
let clockOffset = 0; // serverTime - localNow (ms)
let endsAt = null; // local epoch ms when the current phase ends

function connect() {
  const es = new EventSource("/events");
  es.onmessage = (e) => {
    try {
      onState(JSON.parse(e.data));
    } catch {
      /* ignore malformed frame */
    }
  };
  es.onerror = () => {
    el.status.textContent = "reconnecting…";
    // EventSource reconnects automatically.
  };
}

function onState(s) {
  state = s;
  if (s.serverTime) {
    const srv = Date.parse(s.serverTime);
    if (!Number.isNaN(srv)) clockOffset = srv - Date.now();
  }
  if (typeof s.secondsRemaining === "number" && s.secondsRemaining > 0) {
    endsAt = Date.now() + clockOffset + s.secondsRemaining * 1000;
  } else {
    endsAt = null;
  }
  render();
}

function remaining() {
  if (endsAt == null) return null;
  return Math.max(0, (endsAt - (Date.now() + clockOffset)) / 1000);
}

const CAT = { good: "cat-good", bad: "cat-bad", chaos: "cat-chaos" };

function statusText(s) {
  switch (s.phase) {
    case "voting": return "vote now — type 1–" + (s.options?.length || 4);
    case "apply":
    case "resolving": return "winner!";
    case "cooldown": return "next vote soon";
    default: return "standby";
  }
}

function render() {
  const s = state;
  if (!s) return;

  el.app.className = "app phase-" + (s.phase || "idle");
  if (s.phase === "idle" || !s.options || s.options.length === 0) {
    el.app.classList.add("idle-msg");
  }
  el.status.textContent = statusText(s);

  const tallies = s.tallies || [];
  const max = Math.max(1, ...tallies);
  const winnerIdx = s.winner ? s.winner.index : null;
  const showWinner = s.phase === "apply" || s.phase === "resolving" || s.phase === "cooldown";
  const leadIdx = s.phase === "voting" ? leader(tallies) : null;

  const opts = s.options || [];
  // Rebuild only when the option set changes; otherwise update in place.
  if (el.options.childElementCount !== opts.length) {
    el.options.innerHTML = "";
    for (const o of opts) {
      const row = document.createElement("div");
      row.className = "opt";
      row.innerHTML =
        '<div class="fill"></div>' +
        '<div class="num"></div>' +
        '<div class="label"></div>' +
        '<div class="count"></div>';
      el.options.appendChild(row);
    }
  }

  opts.forEach((o, i) => {
    const row = el.options.children[i];
    const votes = tallies[i] || 0;
    row.className = "opt " + (CAT[o.category] || "cat-chaos");
    if (showWinner && winnerIdx === o.index) row.classList.add("winner");
    else if (showWinner) row.classList.add("dim");
    if (leadIdx === i && votes > 0) row.classList.add("lead");
    row.querySelector(".fill").style.width = (100 * votes) / max + "%";
    row.querySelector(".num").textContent = o.index;
    row.querySelector(".label").textContent = o.label;
    row.querySelector(".count").textContent = votes;
  });

  el.round.textContent = s.round ? "round " + s.round : "";
  el.total.textContent = (s.totalVotes || 0) + " votes";
}

function leader(tallies) {
  let idx = -1, best = -1;
  tallies.forEach((c, i) => {
    if (c > best) { best = c; idx = i; }
  });
  return idx;
}

// Smooth countdown independent of the 4 Hz SSE cadence.
function tick() {
  const r = remaining();
  el.countdown.textContent = r == null ? "" : Math.ceil(r);
  requestAnimationFrame(tick);
}

connect();
requestAnimationFrame(tick);
