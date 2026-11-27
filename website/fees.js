// Platform commission on a given volume, at each platform's standard published rate (percent of volume).
const fees = {
  "fees-solana": [["Powder", 0], ["Banana Gun", 0.5], ["Trojan", 0.9], ["Axiom", 0.95], ["GMGN", 1]],
  "fees-perps": [["Powder", 0], ["Axiom", 0.01], ["Based", 0.025], ["pvp.trade", 0.038], ["Phantom", 0.05]],
};

const slider = document.getElementById("volume");
const output = document.getElementById("volume-value");
const dollars = (value, digits) =>
  value.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits });

// The slider is logarithmic: $1,000 at the left, $10,000,000 at the right, rounded to two figures.
function volume() {
  const raw = 10 ** (3 + (Number(slider.value) / 100) * 4);
  const unit = 10 ** (Math.floor(Math.log10(raw)) - 1);
  return Math.round(raw / unit) * unit;
}

function render() {
  const amount = volume();
  output.textContent = dollars(amount, 0);
  for (const [id, rows] of Object.entries(fees)) {
    const highest = Math.max(...rows.map(([, rate]) => rate));
    document.querySelector(`#${id} tbody`).innerHTML = rows
      .map(([name, rate]) => {
        const cost = (amount * rate) / 100;
        const width = highest ? (rate / highest) * 100 : 0;
        return `<tr class="${rate === 0 ? "us" : ""}">
          <th scope="row">${name}</th>
          <td class="rate">${rate === 0 ? "0%" : rate + "%"}</td>
          <td class="bar"><span style="width:${width}%"></span></td>
          <td class="cost">${dollars(cost, cost < 100 && cost > 0 ? 2 : 0)}</td>
        </tr>`;
      })
      .join("");
  }
}

slider.addEventListener("input", render);
render();
