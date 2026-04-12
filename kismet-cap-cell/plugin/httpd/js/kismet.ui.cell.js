(function() {
    if (typeof(kismet_ui) === 'undefined') {
        return;
    }

    console.log("cell ui module loaded");

    // Add a device detail panel for Cell devices
    kismet_ui.AddDeviceDetail("cell_device_detail", "Cell Info", 50, {
        // Always render; we'll just show rows that have data
        filter: function(d) { return true; },
        draw: function(data, element) {
            element.empty();

            var table = $('<table>', { 'class': 'tablelist' });

            function getVal(key) {
                if (!data) return "";
                // Try flat key
                if (data.hasOwnProperty(key) && typeof(data[key]) !== "object")
                    return data[key];
                // Try nested under cell.device
                if (data.hasOwnProperty("cell.device")) {
                    var cd = data["cell.device"];
                    if (typeof(cd) === "object" && cd !== null) {
                        var k = key.replace("cell.device.", "");
                        if (cd.hasOwnProperty(k) && typeof(cd[k]) !== "object")
                            return cd[k];
                    }
                }
                return "";
            }

            var fields = [
                ["ID", "cell.device.fullid"],
                ["MCC", "cell.device.mcc"],
                ["MNC", "cell.device.mnc"],
                ["TAC/LAC", "cell.device.tac"],
                ["CID", "cell.device.cid"],
                ["ARFCN", "cell.device.arfcn"],
                ["PCI", "cell.device.pci"],
                ["RSSI", "cell.device.rssi"],
                ["RSRP", "cell.device.rsrp"],
                ["RSRQ", "cell.device.rsrq"],
                ["Band", "cell.device.band"],
                ["Composite", "cell.full_composite"]
            ];

            function addRow(label, value) {
                if (value === undefined || value === null || value === "" || value === "\"\"") {
                    return;
                }
                if (typeof(value) === "string") {
                    if (value.length >= 2 && value[0] === '"' && value[value.length-1] === '"') {
                        value = value.substring(1, value.length-1);
                    }
                    value = value.replace(/&quot;/g, '"')
                                 .replace(/&amp;/g, '&')
                                 .replace(/&#39;/g, "'")
                                 .replace(/&lt;/g, '<')
                                 .replace(/&gt;/g, '>');
                }
                var tr = $('<tr>');
                tr.append($('<th>').text(label));
                tr.append($('<td>').text(value));
                table.append(tr);
            }

            fields.forEach(function(f) {
                addRow(f[0], getVal(f[1]));
            });

            // Also show cell.* tags (excluding the cell.device.* keys)
            // Tags may be flattened or in the tag map
            var addTag = function(k, v) {
                if (k.indexOf("cell.") === 0 && k.indexOf("cell.device.") !== 0) {
                    if (typeof(v) === "object")
                        return;
                    addRow(k, v);
                }
            };

            Object.keys(data).forEach(function(k) {
                addTag(k, data[k]);
            });

            if (data.hasOwnProperty("kismet.device.base.tags") &&
                typeof(data["kismet.device.base.tags"]) === "object" &&
                data["kismet.device.base.tags"] !== null) {
                var tags = data["kismet.device.base.tags"];
                Object.keys(tags).forEach(function(k) {
                    addTag(k, tags[k]);
                });
            }

            element.append(table);
        }
    });
})();
