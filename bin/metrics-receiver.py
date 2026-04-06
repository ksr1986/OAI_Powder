#!/usr/bin/env python3
"""
Script to receive JSON metrics from gNB via WebSocket.
# [SRSRAN - DISABLED] Originally written for srsRAN; to be updated for OAI.

Requirements:
    pip install websockets

Usage:
    python3 receive_metrics.py [--host HOST] [--port PORT] [--output FILE]

Example:
    python3 receive_metrics.py --host 127.0.0.1 --port 8001 --output metrics.jsonl

# [SRSRAN - DISABLED] IMPORTANT srsRAN Configuration:
#     You need BOTH of these configurations:
#
#     1. In your YAML config file:
#        metrics:
#          enable_json: true
#        remote_control:
#          enabled: true
#          bind_addr: 0.0.0.0
#          port: 8001
#
#     2. When starting gnb, add this CLI argument:
#        gnb -c your_config.yml remote_control metrics --enable_json true
#
#     OR use the shorthand:
#        gnb -c your_config.yml --metrics.enable_json true --remote_control.enabled true \\
#            --remote_control.bind_addr 0.0.0.0 --remote_control.port 8001 \\
#            remote_control metrics --enable_json true
# TODO: Add OAI-specific metrics configuration here
"""

import asyncio
import websockets
import json
import argparse
import sys
from datetime import datetime


async def receive_metrics(host, port, output_file=None):
    """
    Connect to gNB WebSocket server and receive JSON metrics.
    # [SRSRAN - DISABLED] Originally connected to srsRAN WebSocket server.
    # TODO: Update for OAI metrics endpoint.

    Args:
        host: WebSocket server host
        port: WebSocket server port
        output_file: Optional file to write metrics to (in JSON Lines format)
    """
    uri = f"ws://{host}:{port}"

    print(f"Connecting to {uri}...", file=sys.stderr)

    try:
        async with websockets.connect(uri) as websocket:
            print(f"Connected to {uri}", file=sys.stderr)

            # Subscribe to metrics
            subscribe_cmd = {"cmd": "metrics_subscribe"}
            await websocket.send(json.dumps(subscribe_cmd))
            print("Sent metrics_subscribe command", file=sys.stderr)

            # Wait for subscription response
            response = await websocket.recv()
            print(f"Subscription response: {response}", file=sys.stderr)

            # Check if subscription was successful
            response_json = json.loads(response)
            if "error" in response_json:
                print(f"\nError subscribing: {response_json['error']}", file=sys.stderr)

                if "Unknown command type: metrics_subscribe" in response_json['error']:
                    print("\nThe 'metrics_subscribe' command is not available.", file=sys.stderr)

            print("Successfully subscribed to metrics", file=sys.stderr)
            print("Receiving metrics (press Ctrl+C to stop)...\n", file=sys.stderr)

            # Open output file if specified
            file_handle = None
            if output_file:
                file_handle = open(output_file, 'a')
                print(f"Writing metrics to {output_file}", file=sys.stderr)

            try:
                # Receive and process metrics
                while True:
                    message = await websocket.recv()

                    # Add timestamp to the output
                    timestamp = datetime.now().isoformat()

                    try:
                        # Try to parse as JSON for pretty printing
                        metrics_json = json.loads(message)

                        # Print to stdout (pretty formatted)
                        print(f"[{timestamp}]")
                        print(json.dumps(metrics_json, indent=2))
                        print("-" * 80)

                        # Write to file if specified (JSON Lines format - one JSON per line)
                        if file_handle:
                            # Add timestamp to the JSON object
                            metrics_json['_timestamp'] = timestamp
                            file_handle.write(json.dumps(metrics_json) + '\n')
                            file_handle.flush()
                    except json.JSONDecodeError:
                        # If not valid JSON, just print as-is
                        print(f"[{timestamp}] {message}")
                        if file_handle:
                            file_handle.write(f"{timestamp} {message}\n")
                            file_handle.flush()

            except KeyboardInterrupt:
                print("\n\nUnsubscribing from metrics...", file=sys.stderr)

                # Unsubscribe from metrics
                unsubscribe_cmd = {"cmd": "metrics_unsubscribe"}
                await websocket.send(json.dumps(unsubscribe_cmd))

                response = await websocket.recv()
                print(f"Unsubscribe response: {response}", file=sys.stderr)

            finally:
                if file_handle:
                    file_handle.close()
                    print(f"Closed output file: {output_file}", file=sys.stderr)

    except websockets.exceptions.WebSocketException as e:
        print(f"WebSocket error: {e}", file=sys.stderr)
        print("\nMake sure that:", file=sys.stderr)
        # [SRSRAN - DISABLED] print("  1. srsRAN is running", file=sys.stderr)
        print("  1. gNB is running", file=sys.stderr)  # TODO: update for OAI
        print("  2. remote_control.enabled is set to true", file=sys.stderr)
        print("  3. metrics.enable_json is set to true", file=sys.stderr)
        print(f"  4. The server is accessible at {uri}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description='Receive JSON metrics from gNB via WebSocket',  # [SRSRAN - DISABLED] was: srsRAN via WebSocket
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Connect to default host and port
  python3 receive_metrics.py

  # Connect to custom host and port
  python3 receive_metrics.py --host 10.53.1.3 --port 8001

  # Save metrics to a file (JSON Lines format)
  python3 receive_metrics.py --output metrics.jsonl

  # Both custom connection and output file
  python3 receive_metrics.py --host 192.168.1.100 --port 8001 --output metrics.jsonl
        """
    )

    parser.add_argument(
        '--host',
        default='127.0.0.1',
        help='WebSocket server host (default: 127.0.0.1)'
    )

    parser.add_argument(
        '--port',
        type=int,
        default=8001,
        help='WebSocket server port (default: 8001)'
    )

    parser.add_argument(
        '--output', '-o',
        help='Output file to save metrics (JSON Lines format)'
    )

    args = parser.parse_args()

    # Run the async function
    asyncio.run(receive_metrics(args.host, args.port, args.output))


if __name__ == '__main__':
    main()
