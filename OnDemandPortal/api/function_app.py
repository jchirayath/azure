"""
HTTP API + static portal for the on-demand VM (Azure Functions Python v2).

Served by a single Function App, gated by App Service Easy Auth (AAD). With
routePrefix="" (host.json), routes are literal paths:
    GET  /                 -> portal page (index.html)
    GET  /app.js           -> portal script
    POST /api/deploy       -> start building the VM from the golden image
    POST /api/destroy      -> tear the VM down
    GET  /api/status       -> current state + IP / FQDN

Easy Auth provides /.auth/me and /.auth/login/aad and redirects unauthenticated
users to sign in, so every route below is only reached by an authenticated user.
"""
import json
import logging
from pathlib import Path

import azure.functions as func

import shared

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
WWW = Path(__file__).parent / "www"


def _json(payload, status=200):
    return func.HttpResponse(json.dumps(payload), status_code=status, mimetype="application/json")


# ---- API --------------------------------------------------------------------
@app.route(route="api/deploy", methods=["POST"])
def deploy(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.start_deploy())
    except Exception as e:  # noqa: BLE001
        logging.exception("deploy failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/start", methods=["POST"])
def start(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.start_vm())
    except Exception as e:  # noqa: BLE001
        logging.exception("start failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/stop", methods=["POST"])
def stop(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.stop_vm())
    except Exception as e:  # noqa: BLE001
        logging.exception("stop failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/hold", methods=["POST"])
def hold(req: func.HttpRequest) -> func.HttpResponse:
    try:
        days = req.params.get("days")
        if days is None:
            try:
                days = (req.get_json() or {}).get("days")
            except ValueError:
                days = 0
        return _json(shared.set_hold(days))
    except Exception as e:  # noqa: BLE001
        logging.exception("hold failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/destroy", methods=["POST"])
def destroy(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.start_destroy())
    except Exception as e:  # noqa: BLE001
        logging.exception("destroy failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/status", methods=["GET"])
def status(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.get_status())
    except Exception as e:  # noqa: BLE001
        logging.exception("status failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.get_health())
    except Exception as e:  # noqa: BLE001
        logging.exception("health failed")
        return _json({}, 200)


@app.route(route="api/secrets", methods=["GET"])
def secrets(req: func.HttpRequest) -> func.HttpResponse:
    try:
        r = _json(shared.get_secrets())
        r.headers["Cache-Control"] = "no-store"
        return r
    except Exception as e:  # noqa: BLE001
        logging.exception("secrets failed")
        return _json({"error": str(e)}, 500)


def _body(req):
    try:
        return req.get_json() or {}
    except ValueError:
        return {}


# ---- Operations: cost / schedule / snapshots / images / activity / DNS ------
@app.route(route="api/cost", methods=["GET"])
def cost(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.get_cost())
    except Exception as e:  # noqa: BLE001
        logging.exception("cost failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/schedule", methods=["GET", "POST"])
def schedule(req: func.HttpRequest) -> func.HttpResponse:
    try:
        if req.method == "GET":
            return _json(shared.get_schedule())
        b = _body(req)
        return _json(shared.set_schedule(
            bool(b.get("enabled")), b.get("start"), b.get("stop"),
            b.get("days"), b.get("tz")))
    except Exception as e:  # noqa: BLE001
        logging.exception("schedule failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/snapshots", methods=["GET"])
def snapshots(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.list_snapshots())
    except Exception as e:  # noqa: BLE001
        logging.exception("snapshots failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/snapshot", methods=["POST"])
def snapshot(req: func.HttpRequest) -> func.HttpResponse:
    try:
        action = (req.params.get("action") or _body(req).get("action") or "create").lower()
        name = req.params.get("name") or _body(req).get("name")
        if action == "create":
            return _json(shared.create_snapshot())
        if action == "delete":
            return _json(shared.delete_snapshot(name))
        if action == "restore":
            return _json(shared.restore_snapshot(name))
        return _json({"error": f"unknown action {action}"}, 400)
    except Exception as e:  # noqa: BLE001
        logging.exception("snapshot action failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/images", methods=["GET"])
def images(req: func.HttpRequest) -> func.HttpResponse:
    try:
        return _json(shared.list_images())
    except Exception as e:  # noqa: BLE001
        logging.exception("images failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/image", methods=["POST"])
def image(req: func.HttpRequest) -> func.HttpResponse:
    try:
        action = (req.params.get("action") or _body(req).get("action") or "").lower()
        version = req.params.get("version") or _body(req).get("version")
        if action == "recapture":
            return _json(shared.recapture_image())
        if action == "select":
            return _json(shared.set_image(version))
        return _json({"error": f"unknown action {action}"}, 400)
    except Exception as e:  # noqa: BLE001
        logging.exception("image action failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/activity", methods=["GET"])
def activity(req: func.HttpRequest) -> func.HttpResponse:
    try:
        days = req.params.get("days", 7)
        return _json(shared.get_activity(days=days))
    except Exception as e:  # noqa: BLE001
        logging.exception("activity failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/dns", methods=["GET", "POST"])
def dns(req: func.HttpRequest) -> func.HttpResponse:
    try:
        if req.method == "GET":
            return _json(shared.list_dns())
        b = _body(req)
        action = (req.params.get("action") or b.get("action") or "upsert").lower()
        if action == "delete":
            return _json(shared.delete_dns(b.get("name"), b.get("type")))
        return _json(shared.upsert_dns(b.get("name"), b.get("type"), b.get("ttl"), b.get("values")))
    except Exception as e:  # noqa: BLE001
        logging.exception("dns failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/avd", methods=["GET", "POST"])
def avd(req: func.HttpRequest) -> func.HttpResponse:
    try:
        if req.method == "GET":
            return _json(shared.get_avd())
        action = (req.params.get("action") or _body(req).get("action") or "").lower()
        if action == "start":
            return _json(shared.start_avd())
        if action == "stop":
            return _json(shared.stop_avd())
        if action == "deploy":
            return _json(shared.avd_deploy())
        if action == "destroy":
            return _json(shared.avd_destroy())
        return _json({"error": f"unknown action {action}"}, 400)
    except Exception as e:  # noqa: BLE001
        logging.exception("avd failed")
        return _json({"error": str(e)}, 500)


@app.route(route="api/ports", methods=["GET", "POST"])
def ports(req: func.HttpRequest) -> func.HttpResponse:
    try:
        if req.method == "GET":
            return _json(shared.get_ports())
        b = _body(req)
        key = req.params.get("key") or b.get("key")
        want = req.params.get("open") or b.get("open")
        want_open = str(want).lower() in ("1", "true", "yes", "open")
        return _json(shared.set_port(key, want_open))
    except Exception as e:  # noqa: BLE001
        logging.exception("ports failed")
        return _json({"error": str(e)}, 500)


# ---- Scheduled start/stop (timer) -------------------------------------------
# Every 15 min: resume inside the configured window, deallocate outside it.
# Reads the schedule from rg-axa RG tags; no-op unless enabled. Easy Auth does
# not apply to timer triggers, so this runs on the platform's schedule.
@app.timer_trigger(schedule="0 */15 * * * *", arg_name="timer", run_on_startup=False)
def scheduler(timer: func.TimerRequest) -> None:
    try:
        logging.info("scheduler: %s", shared.run_schedule())
    except Exception:  # noqa: BLE001
        logging.exception("scheduler failed")
    try:
        logging.info("avd-idle: %s", shared.run_avd_idle())
    except Exception:  # noqa: BLE001
        logging.exception("avd-idle failed")


# ---- static portal ----------------------------------------------------------
# Single OPTIONAL segment {page?} matches "/" and "/app.js" but NOT a two-segment
# path like "/api/status" — so this UI handler can never shadow the API routes
# (that greedy {*path} catch-all bug returned "not found" for /api/status).
_NOSTORE = {"Cache-Control": "no-store"}


@app.route(route="{page?}", methods=["GET"])
def ui(req: func.HttpRequest) -> func.HttpResponse:
    page = (req.route_params.get("page") or "").lower().strip("/")
    if page == "app.js":
        return func.HttpResponse(
            (WWW / "app.js").read_text(), mimetype="application/javascript", headers=_NOSTORE
        )
    # route -> file; default landing page.
    if page in ("vm", "vm.html", "manage"):
        file = "vm.html"
    elif page in ("credentials", "creds", "secrets"):
        file = "credentials.html"
    elif page in ("ops", "operations", "ops.html"):
        file = "ops.html"
    else:
        file = "index.html"
    return func.HttpResponse(
        (WWW / file).read_text(), mimetype="text/html", headers=_NOSTORE
    )
