// CCLRTE WebUI — Client-side helpers

// Live clock in footer
function updateClock() {
  const el = document.getElementById('clock');
  if (el) el.textContent = new Date().toLocaleTimeString();
}
setInterval(updateClock, 1000);
updateClock();

// Auto-dismiss alerts after 5 seconds
document.querySelectorAll('.alert').forEach(el => {
  setTimeout(() => el.style.transition = 'opacity 0.5s', 4500);
  setTimeout(() => el.style.opacity = '0', 5000);
  setTimeout(() => el.remove(), 5500);
});
