console.log('Client-side code running');

const button = document.getElementById('myButton');
const clusterAddress = window.location.origin;
button.addEventListener('click', function(e) {
  window.location.replace(`https://portaldev.criticalmanufacturing.dev/Enroll?cluster_uri=${encodeURIComponent(clusterAddress)}`);
  console.log('button was clicked');
});


