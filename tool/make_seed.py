"""Builds a project seed from a database pulled off a device.

    python -I tool/make_seed.py <vineviewer.sqlite> <project id> <out.json.gz>

A seed is one project's current state -- fields, drawings, plants, memberships
and every recorded value -- as gzipped JSON. The app bundles it and
`SeedService` loads it into a new vineyard under fresh ids, so the same seed
can start any number of vineyards on any device.

**Only live rows are exported.** Anything soft-deleted is left behind, along
with every row that hangs off it: a seed is a starting point, and a new
vineyard has no undo history through which a deleted row could come back.
Retired plants (status `removed`) are not deleted and are kept, history and
all.

Rows are written with the database's own column names and values, so the
loader inserts them as they are. `version` is the seed format; `schemaVersion`
is the database version the rows were read from, which the loader checks.
"""

import gzip
import json
import sqlite3
import sys

FORMAT_VERSION = 1


def rows(c, sql, args):
    cur = c.execute(sql, args)
    names = [d[0] for d in cur.description]
    return [dict(zip(names, r)) for r in cur.fetchall()]


def main(db_path, project_id, out_path):
    c = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    schema_version = c.execute("PRAGMA user_version").fetchone()[0]

    [project] = rows(
        c, "SELECT * FROM projects WHERE id = ? AND deleted_at IS NULL", (project_id,)
    )

    field_defs = rows(
        c,
        "SELECT * FROM field_defs WHERE project_id = ? AND deleted_at IS NULL "
        "ORDER BY sort_order, created_at",
        (project_id,),
    )
    fields = {f["id"] for f in field_defs}

    objects = [
        o
        for o in rows(
            c,
            "SELECT * FROM map_objects WHERE project_id = ? AND deleted_at IS NULL "
            "ORDER BY field_def_id, sort_order, created_at",
            (project_id,),
        )
        if o["field_def_id"] in fields
    ]
    object_ids = {o["id"] for o in objects}

    plants = rows(
        c,
        "SELECT * FROM plants WHERE project_id = ? AND deleted_at IS NULL "
        "ORDER BY carrier_id, position_idx",
        (project_id,),
    )
    plant_ids = {p["id"] for p in plants}
    for p in plants:
        # A carrier or predecessor that did not make it into the seed would be
        # a dangling reference, and the first one fails the foreign key.
        if p["carrier_id"] not in object_ids:
            p["carrier_id"] = None
        if p["predecessor_id"] not in plant_ids:
            p["predecessor_id"] = None

    memberships = [
        m
        for m in rows(
            c,
            "SELECT m.* FROM plant_memberships m JOIN plants p ON p.id = m.plant_id "
            "WHERE p.project_id = ? ORDER BY m.plant_id, m.field_def_id",
            (project_id,),
        )
        if m["plant_id"] in plant_ids
        and m["object_id"] in object_ids
        and m["field_def_id"] in fields
    ]

    events = [
        e
        for e in rows(
            c,
            "SELECT e.* FROM field_events e JOIN plants p ON p.id = e.plant_id "
            "WHERE p.project_id = ? AND e.deleted_at IS NULL "
            "ORDER BY e.plant_id, e.field_def_id, e.observed_at, e.recorded_at",
            (project_id,),
        )
        if e["plant_id"] in plant_ids and e["field_def_id"] in fields
    ]

    seed = {
        "version": FORMAT_VERSION,
        "schemaVersion": schema_version,
        "name": project["name"],
        "project": {
            k: project[k]
            for k in (
                "image_width",
                "image_height",
                "image_offset_x",
                "image_offset_y",
                "image_scale_x",
                "image_scale_y",
                "image_rotation",
                "scale_ref_px",
                "scale_ref_length",
                "scale_unit",
                "identifier_template",
            )
        },
        "fieldDefs": field_defs,
        "mapObjects": objects,
        "plants": plants,
        "plantMemberships": memberships,
        "fieldEvents": events,
    }
    # Project ids inside the rows are replaced on load; dropping them here
    # keeps the device's ids out of the APK.
    for table in ("fieldDefs", "mapObjects", "plants"):
        for r in seed[table]:
            del r["project_id"]

    data = json.dumps(seed, separators=(",", ":")).encode()
    with gzip.open(out_path, "wb", compresslevel=9) as f:
        f.write(data)

    print(
        f"{project['name']}: {len(field_defs)} fields, {len(objects)} objects, "
        f"{len(plants)} plants, {len(memberships)} memberships, "
        f"{len(events)} events (schema v{schema_version})"
    )


if __name__ == "__main__":
    main(*sys.argv[1:])
