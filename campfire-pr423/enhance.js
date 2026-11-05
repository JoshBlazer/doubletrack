// Doubletrack report enhancements. Optional: every page works without this file.
// Adds severity filters on the findings page and copy buttons on copyable blocks.
(function () {
  "use strict";

  var form = document.querySelector("form.filters");
  if (form) {
    form.hidden = false;
    form.addEventListener("change", function () {
      var shown = {};
      form.querySelectorAll("input[name=severity]").forEach(function (box) { shown[box.value] = box.checked; });
      document.querySelectorAll(".severity-group").forEach(function (group) {
        group.hidden = !shown[group.getAttribute("data-severity")];
      });
    });
  }

  document.querySelectorAll("pre.copyable").forEach(function (pre) {
    if (!navigator.clipboard) return;
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy-button";
    button.textContent = "Copy command";
    button.addEventListener("click", function () {
      navigator.clipboard.writeText(pre.textContent.trim()).then(function () {
        button.textContent = "Copied";
      });
    });
    pre.insertAdjacentElement("afterend", button);
  });
})();
