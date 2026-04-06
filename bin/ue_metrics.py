#!/usr/bin/env python3
import json
import time

from enum import Enum

import quectel_control

class SCellResponse(Enum):
    COMMAND = 0
    STATE = 1
    MODE = 2
    DUPLEXMODE = 3
    MCC = 4
    MNC = 5
    CELLID = 6
    PCID = 7
    TAC = 8
    ARFCN = 9
    BAND = 10
    BANDWIDTH = 11
    RSRP = 12
    RSRQ = 13
    SINR = 14
    TXPOWER = 15
    SRXLEV = 16

ue_client = quectel_control.QuectelControlClient()
while True:
    response = ue_client.servingcell()
    if "QENG" in response:
        t = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        resp_list = response.split(',')
        try:
            out_dict = {k:v for k,v in zip([member.name for member in SCellResponse], resp_list)}
            out_dict['time'] = t
            print(json.dumps(out_dict))
        except IndexError:
            pass
    time.sleep(1)
