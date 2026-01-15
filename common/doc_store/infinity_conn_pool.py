#
#  Copyright 2025 The InfiniFlow Authors. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
import logging
import time

import infinity
from infinity.connection_pool import ConnectionPool
from infinity.errors import ErrorCode

from common import settings
from common.decorator import singleton


@singleton
class InfinityConnectionPool:

    def __init__(self):
        if hasattr(settings, "INFINITY"):
            self.INFINITY_CONFIG = settings.INFINITY
        else:
            self.INFINITY_CONFIG = settings.get_base_config("infinity", {"uri": "infinity:23817"})

        infinity_uri = self.INFINITY_CONFIG["uri"]

        # Robust URI parsing
        host = "127.0.0.1"
        port = 23817

        try:
            # Strip protocol if present
            clean_uri = infinity_uri
            if "://" in clean_uri:
                clean_uri = clean_uri.split("://")[-1]

            # Remove any trailing slashes
            clean_uri = clean_uri.rstrip("/")

            if ":" in clean_uri:
                parts = clean_uri.split(":")
                if len(parts) == 2:
                    host, port_str = parts
                    port = int(port_str)
                else:
                    logging.warning(f"Unexpected Infinity URI format: {infinity_uri}. Trying to parse anyway.")
                    # Fallback: assume last part is port, second to last is host
                    port = int(parts[-1])
                    host = parts[-2]
            else:
                # If no port specified, assume host only (unlikely but possible)
                host = clean_uri

            self.infinity_uri = infinity.common.NetworkAddress(host, port)
        except Exception as e:
            logging.error(f"Failed to parse Infinity URI '{infinity_uri}': {e}. Using default 127.0.0.1:23817")
            self.infinity_uri = infinity.common.NetworkAddress("127.0.0.1", 23817)

        for _ in range(24):
            try:
                conn_pool = ConnectionPool(self.infinity_uri, max_size=4)
                inf_conn = conn_pool.get_conn()
                res = inf_conn.show_current_node()
                if res.error_code == ErrorCode.OK and res.server_status in ["started", "alive"]:
                    self.conn_pool = conn_pool
                    conn_pool.release_conn(inf_conn)
                    break
            except Exception as e:
                logging.warning(f"{str(e)}. Waiting Infinity {infinity_uri} to be healthy.")
                time.sleep(5)

        if self.conn_pool is None:
            msg = f"Infinity {infinity_uri} is unhealthy in 120s."
            logging.error(msg)
            raise Exception(msg)

        logging.info(f"Infinity {infinity_uri} is healthy.")

    def get_conn_pool(self):
        return self.conn_pool

    def refresh_conn_pool(self):
        try:
            inf_conn = self.conn_pool.get_conn()
            res = inf_conn.show_current_node()
            if res.error_code == ErrorCode.OK and res.server_status in ["started", "alive"]:
                return self.conn_pool
            else:
                raise Exception(f"{res.error_code}: {res.server_status}")

        except Exception as e:
            logging.error(str(e))
            if hasattr(self, "conn_pool") and self.conn_pool:
                self.conn_pool.destroy()
                self.conn_pool = ConnectionPool(self.infinity_uri, max_size=32)
                return self.conn_pool

    def __del__(self):
        if hasattr(self, "conn_pool") and self.conn_pool:
            self.conn_pool.destroy()


INFINITY_CONN = InfinityConnectionPool()
