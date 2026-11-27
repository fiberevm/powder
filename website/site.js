// Every number on the page comes from here. Measured November 2026 on an M4 Max MacBook Pro,
// macOS 26.6, Chrome 158; see the method note under the charts.

// Brand icons are each product's own site icon, shown so the rows are recognisable at a glance.
const icons = {
  Powder: "icon.png",
  "Hyperliquid web": "logos/hyperliquid.png",
  Jupiter: "logos/jupiter.png",
  "DEX Screener": "logos/dexscreener.png",
  GMGN: "logos/gmgn.png",
  Axiom: "logos/axiom.png",
  "Banana Gun": "logos/bananagun.png",
  Trojan: "logos/trojan.png",
  Based: "logos/based.png",
  "pvp.trade": "logos/pvp.png",
  Phantom: "logos/phantom.png",
};
const brand = (name) => `<img class="logo" src="${icons[name]}" width="18" height="18" alt="" loading="lazy"><span>${name}</span>`;

const products = ["Powder", "Hyperliquid web", "Jupiter", "DEX Screener", "GMGN"];

// value: what the bar shows, the average of the runs. text: the same, as written beside the bar.
const charts = [
  {
    title: "Time to first chart",
    unit: "milliseconds, first visit",
    rows: [[696, "696 ms"], [2055, "2,055 ms"], [2253, "2,253 ms"], [3213, "3,213 ms"], [2798, "2,798 ms"]],
  },
  {
    title: "Memory in use",
    unit: "MB, whole app or whole browser",
    rows: [[341, "341 MB"], [2091, "2,091 MB"], [1486, "1,486 MB"], [1974, "1,974 MB"], [1714, "1,714 MB"]],
  },
  {
    title: "Processor while idle",
    unit: "% of one core per live market, streaming, hands off",
    rows: [[2.7, "2.7%"], [14.0, "14%"], [35.7, "36%"], [3.3, "3% · chart only"], [11.6, "12%"]],
  },
];

// Stages of one order, in milliseconds. "ours" is time spent in Powder's own code.
const paths = [
  {
    title: "Hyperliquid market order",
    seen: "Shown on screen at 0 ms",
    stages: [
      { name: "Sign", ms: 0.08, text: "0.08 ms", ours: true },
      { name: "Network and exchange", ms: 780, text: "780 ms" },
    ],
  },
  {
    title: "Solana swap",
    seen: "Shown on screen at 0 ms",
    stages: [
      { name: "Sign", ms: 0.05, text: "0.05 ms", ours: true },
      { name: "Send", ms: 82, text: "82 ms" },
      { name: "Land in a block", ms: 626, text: "626 ms" },
    ],
  },
];

const fees = {
  "fees-solana": [["Powder", 0], ["Banana Gun", 0.5], ["Trojan", 0.9], ["Axiom", 0.95], ["GMGN", 1]],
  "fees-perps": [["Powder", 0], ["Axiom", 0.01], ["Based", 0.025], ["pvp.trade", 0.038], ["Phantom", 0.05]],
};

// ---- Benchmarks: one small bar chart per measure, Powder picked out, the rest neutral.

document.getElementById("charts").innerHTML = charts
  .map((chart) => {
    const max = Math.max(...chart.rows.map(([value]) => value));
    const best = Math.min(...chart.rows.map(([value]) => value));
    const rows = chart.rows
      .map(([value, text], index) => {
        const mine = index === 0;
        return `<tr class="${mine ? "us" : ""}" title="${products[index]}: ${text}">
          <th scope="row">${brand(products[index])}</th>
          <td class="track"><span style="width:${Math.max((value / max) * 100, 0.6)}%"></span></td>
          <td class="value">${text}${value === best ? ' <em>best</em>' : ""}</td>
        </tr>`;
      })
      .join("");
    return `<figure class="chart${chart === charts[0] ? " wide" : ""}">
      <figcaption><b>${chart.title}</b><span>${chart.unit}</span></figcaption>
      <table><tbody>${rows}</tbody></table>
    </figure>`;
  })
  .join("");

document.getElementById("bench-method").textContent =
  "Method. Each figure is the average of its runs. Powder: time from the process starting until candles are drawn (eleven launches); memory and processor for the whole app with two live markets, each a chart, an order book and a trade tape. " +
  "Web: a fresh Chrome profile with one tab; time from the page starting to load, in an already-open browser, until its chart canvas holds candles; memory and processor summed over every process Chrome needs for that tab (an empty Chrome is 280 MB and 0.3%). " +
  "Processor is the average over 30 seconds with nothing touched; Powder measured 5.3% with its two markets, shown here per market. All windows maximised. Measured November 2026 on an M4 Max MacBook Pro, macOS 26.6, Chrome 158. " +
  "DEX Screener is a chart viewer with no order book or tape, so it has less to keep up to date. Axiom's chart sits behind a login and was not measured.";

// ---- Order path: stages to scale, with Powder's own (sub-millisecond) part marked rather than drawn to scale.

document.getElementById("paths").innerHTML = paths
  .map((path) => {
    const total = path.stages.reduce((sum, stage) => sum + stage.ms, 0);
    const bar = path.stages
      .map((stage) =>
        stage.ours
          ? `<span class="tick" title="${stage.name}: ${stage.text}"></span>`
          : `<span class="seg" style="flex:${stage.ms}" title="${stage.name}: ${stage.text}"></span>`,
      )
      .join("");
    const legend = path.stages
      .map((stage) => `<li class="${stage.ours ? "ours" : ""}"><span>${stage.name}</span><b>${stage.text}</b></li>`)
      .join("");
    return `<div class="path">
      <div class="path-head"><b>${path.title}</b><span>${Math.round(total).toLocaleString("en-US")} ms to confirmed</span></div>
      <div class="bar">${bar}</div>
      <ol>${legend}</ol>
      <p class="seen">${path.seen}</p>
    </div>`;
  })
  .join("");

// ---- Commission slider: logarithmic, $1,000 at the left to $10,000,000 at the right.

const slider = document.getElementById("volume");
const output = document.getElementById("volume-value");
const dollars = (value, digits) =>
  value.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits });

function volume() {
  const raw = 10 ** (3 + (Number(slider.value) / 100) * 4);
  const unit = 10 ** (Math.floor(Math.log10(raw)) - 1);
  return Math.round(raw / unit) * unit;
}

function renderFees() {
  const amount = volume();
  output.textContent = dollars(amount, 0);
  for (const [id, rows] of Object.entries(fees)) {
    const highest = Math.max(...rows.map(([, rate]) => rate));
    document.querySelector(`#${id} tbody`).innerHTML = rows
      .map(([name, rate]) => {
        const cost = (amount * rate) / 100;
        return `<tr class="${rate === 0 ? "us" : ""}">
          <th scope="row">${brand(name)}</th>
          <td class="rate">${rate}%</td>
          <td class="bar"><span style="width:${rate === 0 ? "3px" : (rate / highest) * 100 + "%"}"></span></td>
          <td class="cost">${dollars(cost, cost < 100 && cost > 0 ? 2 : 0)}</td>
        </tr>`;
      })
      .join("");
  }
}

slider.addEventListener("input", renderFees);
renderFees();

// ---- The version on the download buttons comes from the release the site was built with.

fetch("downloads/version.txt")
  .then((reply) => (reply.ok ? reply.text() : ""))
  .then((text) => {
    const version = text.trim().replace(/^v/, "");
    if (version) document.getElementById("version").textContent = version;
  })
  .catch(() => {});
