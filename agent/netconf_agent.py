import sys
import time
import socket
import threading
import logging
import paramiko
from lxml import etree
from driver.netconf_driver import NetconfHardwareDriver

# Configure Logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - NETCONF Agent - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

NETCONF_DELIMITER = b"]]>]]>"
netconf_hw = NetconfHardwareDriver()

class NetconfServer(paramiko.ServerInterface):
    def check_channel_request(self, kind, chanid):
        if kind == 'session':
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_auth_password(self, username, password):
        if username == 'sdn' and password == 'quantum':
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_channel_subsystem_request(self, channel, name):
        if name == 'netconf':
            return True
        return False

def handle_netconf_session(channel):
    """Handles NETCONF capability exchange and incoming XML framing."""
    hello_msg = """<hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
  <capabilities>
    <capability>urn:ietf:params:netconf:base:1.0</capability>
    <capability>urn:quantum:sdn:netconf-switch?module=quantum-netconf-switch&amp;revision=2026-08-24</capability>
  </capabilities>
  <session-id>101</session-id>
</hello>"""
    
    channel.send(hello_msg.encode('utf-8') + NETCONF_DELIMITER)
    buffer = b""

    while True:
        try:
            data = channel.recv(4096)
            if not data:
                break
            
            buffer += data
            if NETCONF_DELIMITER in buffer:
                requests = buffer.split(NETCONF_DELIMITER)
                for req in requests[:-1]:
                    if req.strip():
                        process_rpc(channel, req)
                buffer = requests[-1]
                
        except Exception as e:
            logger.error(f"Session error: {e}")
            break
            
    channel.close()

def process_rpc(channel, xml_data):
    """Parses incoming RPCs and executes actions via the dedicated NETCONF driver."""
    try:
        root = etree.fromstring(xml_data)
        
        if root.tag.endswith('hello'):
            logger.info("Received client <hello> capabilities.")
            return

        message_id = root.get('message-id', '1')
        
        # Match set-netconf-switch RPC from quantum-netconf-switch.yang
        set_cc = root.find('.//*{urn:quantum:sdn:netconf-switch}set-netconf-switch')
        if set_cc is not None:
            state_node = set_cc.find('.//*{urn:quantum:sdn:netconf-switch}state')
            state_val = state_node.text.strip().lower() == 'true' if state_node is not None else False
            
            logger.info(f"Executing set-netconf-switch RPC with state: {state_val}")
            success = netconf_hw.set_netconf_switch_state(state_val)
            
            reply = f"""<rpc-reply message-id="{message_id}" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
    <success>{'true' if success else 'false'}</success>
    <message>NETCONF hardware state set to {state_val}.</message>
</rpc-reply>"""
            channel.send(reply.encode('utf-8') + NETCONF_DELIMITER)
            return

        # Default fallback response
        reply = f"""<rpc-reply message-id="{message_id}" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
    <rpc-error>
        <error-type>application</error-type>
        <error-tag>operation-not-supported</error-tag>
        <error-severity>error</error-severity>
        <error-message>Operation not implemented on this edge node.</error-message>
    </rpc-error>
</rpc-reply>"""
        channel.send(reply.encode('utf-8') + NETCONF_DELIMITER)

    except etree.XMLSyntaxError:
        logger.error("Malformed XML received.")

def start_server(host='0.0.0.0', port=8300):
    """Starts the SSH listener for NETCONF subsystem connections."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        sock.listen(10)
        logger.info(f"Quantum NETCONF Agent listening on SSH Port {port}...")
    except Exception as e:
        logger.critical(f"Failed to bind port {port}: {e}")
        sys.exit(1)

    host_key = paramiko.RSAKey.generate(2048)

    while True:
        client, addr = sock.accept()
        logger.info(f"Incoming NETCONF connection from {addr[0]}")
        try:
            transport = paramiko.Transport(client)
            transport.add_server_key(host_key)
            server = NetconfServer()
            
            transport.start_server(server=server)
            channel = transport.accept(20)
            
            if channel is None:
                continue

            threading.Thread(target=handle_netconf_session, args=(channel,)).start()
        except Exception as e:
            logger.error(f"SSH negotiation failed: {e}")

if __name__ == '__main__':
    start_server(port=8300)
