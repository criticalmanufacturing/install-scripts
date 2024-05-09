import os
from flask import Flask, render_template
from openshift import client, config

os.environ['PYTHONUNBUFFERED'] = '1'

app = Flask(__name__)


def get_host_ip():
  return os.getenv('HOST_IP')

def get_cmos_route_host():
    # Load OpenShift config from default location
    config.load_incluster_config()

    # Create an instance of the route API
    route_v1 = client.RouteV1Api()

    try:
        # List all routes in the 'cmos' namespace
        routes_list = route_v1.list_namespaced_route(namespace='cmos', watch=False)
        
        print(f"Routes List: {routes_list}")

        # Assuming there's only one route in the 'cmos' namespace, retrieve its 'Requested Host'
        if routes_list.items:
            print(f"Route's Requested Host: {routes_list.items[0].spec.host}")
            return routes_list.items[0].spec.host
        else:
            raise("No routes found in the 'cmos' namespace.")
    
    except Exception as e:
        print(f"Error occurred: {str(e)}")

@app.route('/', methods=['GET'])
def serve_web_interface():
    # Get the host IP address
    # host_ip = get_host_ip()
    # Get the namespace of the CMOS app
    # cmos_namespace = "testNamespace"

    # Get the requested host from the cmos route
    cmos_route_host = get_cmos_route_host()

    # Render the HTML template with the host IP address
    # return render_template('index.html', host_ip=host_ip, cmos_namespace=cmos_namespace)
    return render_template('index.html', cmos_route_host=cmos_route_host)

if __name__ == '__main__':
    # Change directory to where index.html is located
    os.chdir('/usr/src/app/')
    app.run(host='0.0.0.0', port=8080)