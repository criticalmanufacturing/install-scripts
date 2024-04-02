console.log('Client-side code running');

const button = document.getElementById('myButton');
button.addEventListener('click', function(e) {
  window.location.replace("https://portal.criticalmanufacturing.com/");
  console.log('button was clicked');
});


