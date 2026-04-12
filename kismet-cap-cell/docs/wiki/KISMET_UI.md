# Kismet UI Reference (Cell Plugin)

This page documents what the cell plugin adds to Kismet UI and what fields are shown.

Plugin UI script:
- `plugin/httpd/js/kismet.ui.cell.js`

## Added Device Detail Panel

Panel name:
- `Cell Info`

Registration:
- added via `kismet_ui.AddDeviceDetail(...)`

Render behavior:
- always available in device detail context
- renders a table and only shows rows with non-empty values

## Displayed Rows (explicit field mapping)

Row label -> Kismet field key:
- `ID` -> `cell.device.fullid`
- `MCC` -> `cell.device.mcc`
- `MNC` -> `cell.device.mnc`
- `TAC/LAC` -> `cell.device.tac`
- `CID` -> `cell.device.cid`
- `ARFCN` -> `cell.device.arfcn`
- `PCI` -> `cell.device.pci`
- `RSSI` -> `cell.device.rssi`
- `RSRP` -> `cell.device.rsrp`
- `RSRQ` -> `cell.device.rsrq`
- `Band` -> `cell.device.band`
- `Composite` -> `cell.full_composite`

## Additional Cell Tags Shown

The panel also displays any tag keys beginning with `cell.` except `cell.device.*`.

Sources checked:
- flattened keys on device object
- tag map under `kismet.device.base.tags`

## Value Cleanup Rules

Before display, the UI script:
- strips wrapped quotes
- decodes common HTML entities (`&quot;`, `&amp;`, `&#39;`, `&lt;`, `&gt;`)
- skips object-valued fields/tags

## What Operators Should Expect

- Not all rows appear for every RAT/phone; empty values are hidden
- Rows change as serving/neighbor cells update
- `Composite` can provide a combined identifier when present
