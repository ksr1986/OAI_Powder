#!/usr/bin/env python3
import serial
import sys

import zmq
import zmq.ssh


UE_COMMANDS = {
    "up": "AT+CFUN=1",
    "down": "AT+CFUN=0",
    "airplane": "AT+CFUN=4",
    "status": "AT+CFUN?",
    "imsi": "AT+CIMI",
    "scan": 'AT+QSCAN=2',
    "servingcell": 'AT+QENG="servingcell"',
    "hello": "AT",
}

AT_PORT = "/dev/ttyUSB2"
AT_BAUDRATE = 115200
AT_TIMEOUT = 1

ZMQ_PORT = 5555
ZMQ_SERVER_ADDRESS = f"tcp://*:{ZMQ_PORT}"
ZMQ_CLIENT_ADDRESS = f"tcp://127.0.0.1:{ZMQ_PORT}"
ZMQ_POLLER_TIMEOUT = 1000


def run_command(command):
    with serial.Serial(AT_PORT, AT_BAUDRATE) as ser:
        ser.write(UE_COMMANDS[command].encode() + b"\r")
        return(ser.read_until(b"OK\r"))


class QuectelControlServer:
    def __init__(
        self,
        port=AT_PORT,
        baudrate=AT_BAUDRATE,
        timeout=AT_TIMEOUT,
        zmq_address=ZMQ_SERVER_ADDRESS,
    ):
        self.__ser = serial.Serial(port, baudrate, timeout=timeout)
        self.__context = zmq.Context()
        self.__socket = self.__context.socket(zmq.REP)
        self.__socket.bind(zmq_address)

    def __execute_command(self, command):
        response = ""
        if command not in UE_COMMANDS:
             return "Invalid command"
        self.__ser.write(UE_COMMANDS[command].encode() + b"\r")
        if command == "scan":
            self.__ser.timeout = 30
        while True:
            chunk = self.__ser.read_until(b"OK\r")
            if not chunk:
                # Timeout occurred
                break
            response += chunk.decode()
            break
        if command == "scan":
            self.__ser.timeout = 1
        return response

    def run(self):
        poller = zmq.Poller()
        poller.register(self.__socket, zmq.POLLIN)
        while True:
            socks = dict(poller.poll(ZMQ_POLLER_TIMEOUT))
            if self.__socket in socks and socks[self.__socket] == zmq.POLLIN:
                command = self.__socket.recv_string()
                print(f"Received command: {command}")
                if command == "hello":
                    response = self.hello_back()
                else:
                    response = self.__execute_command(command)
                print(f"Sending response: {response}")
                self.__socket.send_string(response)

    def hello_back(self):
        return "Hello from QuectelControlServer"

class QuectelControlClient():
    def __init__(
        self,
        zmq_address="tcp://127.0.0.1:5555",
        server=None,
    ):
        self.__zmq_address = zmq_address
        self.__server = server
        self.__setup_zmq_socket()

    def __trimmer(func):
        def wrapper(self):
            response = func(self)
            try:
                response = response.split("\n")[2]
            except IndexError:
                response = "Error"
            return response
        return wrapper

    def __setup_zmq_socket(self):
        self.__context = zmq.Context()
        self.__socket = self.__context.socket(zmq.REQ)
        self.__socket.setsockopt(zmq.LINGER, 0)
        if self.__server:
            zmq.ssh.tunnel_connection(self.__socket, self.__zmq_address, self.__server)
        else:
            self.__socket.connect(self.__zmq_address)

    def __teardown_zmq_socket(self):
        self.__socket.close()
        self.__context.term()

    def __execute_command(self, command):
        self.__socket.send_string(command)
        poller = zmq.Poller()
        poller.register(self.__socket, zmq.POLLIN)
        if poller.poll(ZMQ_POLLER_TIMEOUT):
            response = self.__socket.recv_string()
        else:
            response = "Timeout occurred"
            poller.unregister(self.__socket)
            self.__teardown_zmq_socket()
            self.__setup_zmq_socket()
        return response

    def up(self):
        return self.__execute_command("up")

    def down(self):
        return self.__execute_command("down")

    def airplane(self):
        return self.__execute_command("airplane")

    @__trimmer
    def status(self):
        response = self.__execute_command("status")
        return(response)

    @__trimmer
    def imsi(self):
        response = self.__execute_command("imsi")
        return(response)

    @__trimmer
    def servingcell(self):
        response = self.__execute_command("servingcell")
        return(response)

    def scan(self):
        return self.__execute_command("scan")

    def hello(self):
        return self.__execute_command("hello")

if __name__ == "__main__":
    usage = "Usage: python3 quectel_control.py [command]\n"
    usage += "Available commands: \n"
    usage += "\n".join(UE_COMMANDS.keys())
    if len(sys.argv) > 2:
        print(usage)
        sys.exit(1)
    elif len(sys.argv) == 2:
        command = sys.argv[1]
        if command not in UE_COMMANDS:
            print(f"Invalid command {command}")
            print(usage)
            sys.exit(1)
        qcc = QuectelControlClient()
        if command == "up":
            print(qcc.up())
        elif command == "down":
            print(qcc.down())
        elif command == "airplane":
            print(qcc.airplane())
        elif command == "status":
            print(qcc.status())
        elif command == "imsi":
            print(qcc.imsi())
        elif command == "servingcell":
            print(qcc.servingcell())
        elif command == "scan":
            print(qcc.scan())
        elif command == "hello":
            print(qcc.hello())
    else:
        ue = QuectelControlServer()
        ue.run()
