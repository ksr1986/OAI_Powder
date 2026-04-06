#!/usr/bin/env python3
import datetime
import sys

from textual.app import App, ComposeResult
from textual.widgets import Footer, Header, RichLog

import quectel_control

class UEApp(App):
    BINDINGS = [
        ("q", "quit", "Quit"),
        ("a", "airplane", "Airplane mode"),
        ("u", "up", "Power up"),
        ("d", "down", "Power down"),
        ("s", "servingcell", "Serving cell"),
        ("i", "imsi", "IMSI"),
        ("h", "hello", "Check zmq connection"),
        # ("c", "scan", "Check zmq connection"),
    ]

    def __init__(self, server=None, **kwargs):
        super().__init__(**kwargs)
        self.ue_client = None
        self.rlog = None
        if server:
            self.ue_client = quectel_control.QuectelControlClient(server=server)
        else:
            self.ue_client = quectel_control.QuectelControlClient()

    def _logit(func):
        def wrapper(self):
            response = func(self)
            t_str = datetime.datetime.now().isoformat(sep=' ', timespec='milliseconds')
            self.rlog.write(f"{t_str} {response}")
            self.log.info(response)
        return wrapper

    def compose(self) -> ComposeResult:
        yield Header()
        self.rlog = RichLog()
        yield self.rlog
        yield Footer()

    @_logit
    def action_up(self):
        return self.ue_client.up()

    @_logit
    def action_down(self):
        return self.ue_client.down()

    @_logit
    def action_airplane(self):
        return self.ue_client.airplane()

    @_logit
    def action_servingcell(self):
        return self.ue_client.servingcell()

    @_logit
    def action_imsi(self):
        return self.ue_client.imsi()

    @_logit
    def action_scan(self):
        return self.ue_client.scan()

    @_logit
    def action_hello(self):
        return self.ue_client.hello()


if __name__ == "__main__":
    if len(sys.argv) == 2:
        app = UEApp(server=sys.argv[1])
    else:
        app = UEApp()

    app.run()
