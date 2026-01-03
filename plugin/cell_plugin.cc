/*
 * Cell datasource/phy plugin for Kismet
 *
 * Registers a 'cell' datasource which launches the external capture
 * binary (kismet_cap_cell_capture) to read the Android JSON feed on
 * tcp://127.0.0.1:8765 by default. JSON frames are delivered to Kismet
 * via the standard external capture protocol as KDS_JSON blocks with
 * type "cell".
 *
 * Build:  make  (requires Kismet source tree at KIS_SRC_DIR)
 * Install: make install   (or make userinstall)
 */

#include <config.h>
#include <string>

#include <globalregistry.h>
#include <datasourcetracker.h>
#include <kis_datasource.h>
#include <messagebus.h>
#include <plugintracker.h>
#include <version.h>
#include <configfile.h>
#include <functional>
#include <util.h>
#include <packet.h>
#include <packetchain.h>
#include <devicetracker.h>
#include <entrytracker.h>
#include <trackedelement.h>
#include <kis_httpd_registry.h>
#include <macaddr.h>
#include <fmt.h>
#include <nlohmann/json.hpp>
#include <sys/time.h>
#include <stdexcept>

class kis_datasource_cell : public kis_datasource {
public:
    kis_datasource_cell(shared_datasource_builder in_builder) :
        kis_datasource(in_builder) {
        set_int_source_cap_interface("cellstream");
        set_int_source_hardware("android");
        // External capture binary must be in PATH or at this name
        set_int_source_ipc_binary("kismet_cap_cell_capture");
    }

    virtual ~kis_datasource_cell() { }

protected:
    virtual void open_interface(std::string in_definition, unsigned int in_transaction,
            open_callback_t in_cb) override {
        kis_datasource::open_interface(in_definition, in_transaction, in_cb);
    }
};

class cell_tracked_common : public tracker_component {
public:
    cell_tracked_common() { register_fields(); reserve_fields(NULL); }
    cell_tracked_common(int id) : tracker_component(id) { register_fields(); reserve_fields(NULL); }
    cell_tracked_common(int id, std::shared_ptr<tracker_element_map> e) :
        tracker_component(id) { register_fields(); reserve_fields(e); }

    virtual uint32_t get_signature() const override {
        return adler32_checksum("cell_tracked_common");
    }

    virtual std::shared_ptr<tracker_element> clone_type() noexcept override {
        auto r = std::make_shared<cell_tracked_common>();
        r->set_id(this->get_id());
        return r;
    }

    __Proxy(fullid, std::string, std::string, std::string, fullid);
    __Proxy(rat, std::string, std::string, std::string, rat);
    __Proxy(mcc, std::string, std::string, std::string, mcc);
    __Proxy(mnc, std::string, std::string, std::string, mnc);
    __Proxy(tac, std::string, std::string, std::string, tac);
    __Proxy(cid, std::string, std::string, std::string, cid);
    __Proxy(arfcn, std::string, std::string, std::string, arfcn);
    __Proxy(pci, std::string, std::string, std::string, pci);
    __Proxy(rssi, std::string, std::string, std::string, rssi);
    __Proxy(rsrp, std::string, std::string, std::string, rsrp);
    __Proxy(rsrq, std::string, std::string, std::string, rsrq);
    __Proxy(band, std::string, std::string, std::string, band);

protected:
    virtual void register_fields() override {
        tracker_component::register_fields();
        register_field("cell.device.fullid", "Full cell id", &fullid);
        register_field("cell.device.rat", "RAT", &rat);
        register_field("cell.device.mcc", "MCC", &mcc);
        register_field("cell.device.mnc", "MNC", &mnc);
        register_field("cell.device.tac", "TAC/LAC", &tac);
        register_field("cell.device.cid", "CID", &cid);
        register_field("cell.device.arfcn", "ARFCN", &arfcn);
        register_field("cell.device.pci", "PCI", &pci);
        register_field("cell.device.rssi", "RSSI", &rssi);
        register_field("cell.device.rsrp", "RSRP", &rsrp);
        register_field("cell.device.rsrq", "RSRQ", &rsrq);
        register_field("cell.device.band", "Band", &band);
    }
private:
    std::shared_ptr<tracker_element_string> fullid, rat, mcc, mnc, tac, cid, arfcn, pci, rssi, rsrp, rsrq, band;
};

class kis_cell_phy : public kis_phy_handler {
public:
    kis_cell_phy(int phyid) : kis_phy_handler(phyid) {
        set_phy_name("CELL");

        packetchain = Globalreg::fetch_mandatory_global_as<packet_chain>();
        entrytracker = Globalreg::fetch_mandatory_global_as<entry_tracker>();
        devicetracker = Globalreg::fetch_mandatory_global_as<device_tracker>();

        pack_comp_common = packetchain->register_packet_component("COMMON");
        pack_comp_json = packetchain->register_packet_component("JSON");
        pack_comp_meta = packetchain->register_packet_component("METABLOB");
        pack_comp_radiodata = packetchain->register_packet_component("RADIODATA");
        pack_comp_gps = packetchain->register_packet_component("GPS");
        pack_comp_devicetag = packetchain->register_packet_component("DEVICETAG");

        cell_common_id =
            Globalreg::globalreg->entrytracker->register_field("cell.device",
                tracker_element_factory<cell_tracked_common>(),
                "Cellular cell");

        packetchain->register_handler(&PacketHandler, this, CHAINPOS_CLASSIFIER, -100);
    }

    virtual ~kis_cell_phy() {
        packetchain->remove_handler(&PacketHandler, CHAINPOS_CLASSIFIER);
    }

    kis_phy_handler *create_phy_handler(int phyid) override {
        return new kis_cell_phy(phyid);
    }

    static int PacketHandler(CHAINCALL_PARMS) {
        kis_cell_phy *cell = (kis_cell_phy *) auxdata;

        if (in_pack->error || in_pack->filtered || in_pack->duplicate)
            return 0;

        auto json = in_pack->fetch<kis_json_packinfo>(cell->pack_comp_json);
        if (json == nullptr)
            return 0;
        if (json->type != "cell")
            return 0;

        nlohmann::json j;
        try {
            j = nlohmann::json::parse(json->json_string);
        } catch (...) {
            return 0;
        }

        auto to_string = [](const nlohmann::json& obj, const std::string& key) -> std::string {
            if (!obj.contains(key))
                return "";
            const auto& v = obj[key];
            if (v.is_null())
                return "";
            if (v.is_string())
                return v.get<std::string>();
            if (v.is_number_integer())
                return fmt::format("{}", v.get<int64_t>());
            if (v.is_number_unsigned())
                return fmt::format("{}", v.get<uint64_t>());
            if (v.is_number_float())
                return fmt::format("{}", v.get<double>());
            if (v.is_boolean())
                return fmt::format("{}", v.get<bool>());
            return v.dump();
        };
        auto to_int = [](const nlohmann::json& obj, const std::string& key) -> std::optional<int> {
            if (!obj.contains(key) || obj[key].is_null())
                return std::nullopt;
            try {
                if (obj[key].is_number_integer() || obj[key].is_number_unsigned())
                    return obj[key].get<int>();
                if (obj[key].is_string())
                    return std::stoi(obj[key].get<std::string>());
            } catch (...) { }
            return std::nullopt;
        };
        struct band_info {
            double fdl_low;
            std::optional<double> ful_low;
            int n_offs;
        };
        static const std::map<int, band_info> lte_bands = {
            {1, {2110.0, 1920.0, 0}}, {2, {1930.0, 1850.0, 600}}, {3, {1805.0, 1710.0, 1200}},
            {4, {2110.0, 1710.0, 1950}}, {5, {869.0, 824.0, 2400}}, {6, {830.0, 875.0, 2650}},
            {7, {2620.0, 2500.0, 2750}}, {8, {925.0, 880.0, 3450}}, {9, {1844.9, 1749.9, 3800}},
            {10, {2110.0, 1710.0, 4150}}, {11, {1475.9, 1427.9, 4750}}, {12, {729.0, 699.0, 5010}},
            {13, {746.0, 777.0, 5180}}, {14, {758.0, 788.0, 5280}}, {17, {734.0, 704.0, 5035}},
            {18, {860.0, 815.0, 5850}}, {19, {875.0, 830.0, 6000}}, {20, {791.0, 832.0, 6150}},
            {21, {1495.9, 1447.9, 6450}}, {22, {3510.0, 3410.0, 6600}}, {23, {2180.0, 2000.0, 7500}},
            {24, {1525.0, 1626.5, 7700}}, {25, {1930.0, 1850.0, 8040}}, {26, {859.0, 814.0, 8690}},
            {27, {852.0, 807.0, 9040}}, {28, {758.0, 703.0, 9210}}, {29, {717.0, std::nullopt, 9660}},
            {30, {2350.0, 2305.0, 9770}}, {31, {462.5, 452.5, 9870}}, {32, {1452.0, std::nullopt, 9920}},
            {33, {1900.0, std::nullopt, 36000}}, {34, {2010.0, std::nullopt, 36200}},
            {35, {1850.0, std::nullopt, 36350}}, {36, {1930.0, std::nullopt, 36950}},
            {37, {1910.0, std::nullopt, 37550}}, {38, {2570.0, std::nullopt, 37750}},
            {39, {1880.0, std::nullopt, 38250}}, {40, {2300.0, std::nullopt, 38650}},
            {41, {2496.0, std::nullopt, 39650}}, {42, {3400.0, std::nullopt, 41590}},
            {43, {3600.0, std::nullopt, 43590}}, {48, {3550.0, std::nullopt, 55240}},
            {65, {2110.0, 1920.0, 65536}}, {66, {2110.0, 1710.0, 66436}},
            {67, {738.0, std::nullopt, 67336}}, {68, {753.0, 698.0, 68336}}, {71, {617.0, 663.0, 13470}},
        };
        static const std::vector<std::tuple<int, int, int>> lte_ranges = {
            {1, 0, 599}, {2, 600, 1199}, {3, 1200, 1949}, {4, 1950, 2399}, {5, 2400, 2649}, {6, 2650, 2749},
            {7, 2750, 3449}, {8, 3450, 3799}, {9, 3800, 4149}, {10, 4150, 4749}, {11, 4750, 4949},
            {12, 5010, 5179}, {13, 5180, 5279}, {14, 5280, 5379}, {17, 5730, 5849}, {18, 5850, 5999},
            {19, 6000, 6149}, {20, 6150, 6449}, {21, 6450, 6599}, {22, 6600, 7399}, {23, 7500, 7699},
            {24, 7700, 8039}, {25, 8040, 8689}, {26, 8690, 9039}, {27, 9040, 9209}, {28, 9210, 9659},
            {29, 9660, 9769}, {30, 9770, 9869}, {31, 9870, 9919}, {32, 9920, 10359}, {33, 36000, 36199},
            {34, 36200, 36349}, {35, 36350, 36949}, {36, 36950, 37549}, {37, 37550, 37749}, {38, 37750, 38249},
            {39, 38250, 38649}, {40, 38650, 39649}, {41, 39650, 41589}, {42, 41590, 43589}, {43, 43590, 45589},
            {48, 55240, 56739}, {65, 65536, 66435}, {66, 66436, 67335}, {67, 67336, 67535}, {68, 68336, 68585},
            {71, 13470, 13719},
        };
        auto derive_band = [](int earfcn) -> std::optional<int> {
            for (const auto& t : lte_ranges) {
                int b, lo, hi;
                std::tie(b, lo, hi) = t;
                if (earfcn >= lo && earfcn <= hi)
                    return b;
            }
            return std::nullopt;
        };

        // Pick the primary cell: first registered=true, else first entry
        nlohmann::json cellj;
        if (j.contains("cells") && j["cells"].is_array() && !j["cells"].empty()) {
            cellj = j["cells"].front();
            for (const auto& c : j["cells"]) {
                if (c.value("registered", false)) {
                    cellj = c;
                    break;
                }
            }
        } else {
            // Backwards compatibility if a single cell is at top level
            cellj = j;
        }

        // Extract identity
        auto fullid = to_string(cellj, "full_cell_key");
        if (fullid.empty())
            fullid = to_string(cellj, "full_cell_id");

        // Always build our composite ID <mcc><mnc>-<tac/lac>-<cid/full_cell_id>
        auto mcc_s = to_string(cellj, "mcc");
        auto mnc_s = to_string(cellj, "mnc");
        auto tac_lac_s = cellj.contains("tac") ? to_string(cellj, "tac") : to_string(cellj, "lac");
        auto cid_s = cellj.contains("full_cell_id") ? to_string(cellj, "full_cell_id") : to_string(cellj, "cid");
        std::stringstream composite_ss;
        composite_ss << mcc_s << mnc_s << "-" << tac_lac_s << "-" << cid_s;
        std::string composite_id = composite_ss.str();

        if (fullid.empty()) {
            fullid = composite_id;
        }
        if (fullid.empty())
            return 0;

        // Build a stable locally-administered MAC from the id
        std::hash<std::string> h;
        uint64_t hv = h(fullid);
        uint8_t macbytes[6];
        macbytes[0] = 0x02; // locally administered, unicast
        macbytes[1] = (hv >> 32) & 0xFF;
        macbytes[2] = (hv >> 24) & 0xFF;
        macbytes[3] = (hv >> 16) & 0xFF;
        macbytes[4] = (hv >> 8) & 0xFF;
        macbytes[5] = hv & 0xFF;
        mac_addr mac(macbytes, 6);

        nlohmann::json arfcn = cellj.contains("nrarfcn") ? cellj["nrarfcn"] :
                               (cellj.contains("earfcn") ? cellj["earfcn"] :
                               (cellj.contains("arfcn") ? cellj["arfcn"] : nlohmann::json()));
        std::string channel = "";
        if (arfcn.is_number()) channel = fmt::format("{}", arfcn.get<int>());
        else if (arfcn.is_string()) channel = arfcn.get<std::string>();
        std::optional<int> earfcn_val = to_int(cellj, "nrarfcn");
        if (!earfcn_val) earfcn_val = to_int(cellj, "earfcn");
        if (!earfcn_val) earfcn_val = to_int(cellj, "arfcn");
        std::optional<int> band_val = to_int(cellj, "band");
        if (!band_val && earfcn_val)
            band_val = derive_band(*earfcn_val);

        auto rssi_j = cellj.contains("rssi") ? cellj["rssi"] : nlohmann::json();
        int rssi = rssi_j.is_number() ? rssi_j.get<int>() : 0;
        int rsrp = cellj.contains("rsrp") && cellj["rsrp"].is_number() ? cellj["rsrp"].get<int>() : 0;
        if (rssi == 0 && rsrp != 0)
            rssi = rsrp; // fall back so UI signal uses something meaningful
        int rsrq = cellj.contains("rsrq") && cellj["rsrq"].is_number() ? cellj["rsrq"].get<int>() : 0;

        auto common = in_pack->fetch_or_add<kis_common_info>(cell->pack_comp_common);
        common->type = packet_basic_data;
        common->phyid = cell->fetch_phy_id();
        common->datasize = 0;
        common->channel = channel;
        common->source = mac;
        common->transmitter = mac;

        auto l1 = in_pack->fetch_or_add<kis_layer1_packinfo>(cell->pack_comp_radiodata);
        l1->signal_type = kis_l1_signal_type_dbm;
        l1->signal_dbm = rssi;
        l1->signal_rssi = rssi;

        // GPS if present
        if (j.contains("lat") && j.contains("lon")) {
            auto gps = in_pack->fetch_or_add<kis_gps_packinfo>(cell->pack_comp_gps);
            gps->merge_partial = true;
            gps->merge_flags = GPS_PACKINFO_MERGE_LOC | GPS_PACKINFO_MERGE_ALT |
                               GPS_PACKINFO_MERGE_SPEED | GPS_PACKINFO_MERGE_HEADING;
            gps->lat = j.value("lat", 0.0);
            gps->lon = j.value("lon", 0.0);
            gps->alt = j.value("alt_m", 0.0);
            gps->speed = j.value("speed_mps", 0.0);
            gps->heading = j.value("bearing_deg", 0.0);
            gps->fix = 3;
            gettimeofday(&(gps->tv), NULL);
        }

        // Update base device
        auto basedev = cell->devicetracker->update_common_device(common, common->source, cell,
                in_pack, (UCD_UPDATE_FREQUENCIES | UCD_UPDATE_PACKETS |
                          UCD_UPDATE_LOCATION | UCD_UPDATE_SEENBY), "Cell");
        if (basedev == nullptr)
            return 0;

        basedev->set_devicename(composite_id);
        basedev->set_commonname(composite_id);
        basedev->set_tracker_type_string(cell->devicetracker->get_cached_devicetype("Cell"));
        if (!channel.empty())
            basedev->set_channel(channel);

        // Attach cell-specific info
        auto celldev = basedev->get_sub_as<cell_tracked_common>(cell->cell_common_id);
        if (celldev == nullptr) {
            celldev = Globalreg::globalreg->entrytracker->get_shared_instance_as<cell_tracked_common>(cell->cell_common_id);
            basedev->insert(celldev);
        }
        celldev->set_fullid(composite_id);
        celldev->set_rat(to_string(cellj, "rat"));
        celldev->set_mcc(to_string(cellj, "mcc"));
        celldev->set_mnc(to_string(cellj, "mnc"));
        celldev->set_tac(cellj.contains("tac") ? to_string(cellj, "tac") : to_string(cellj, "lac"));
        celldev->set_cid(cellj.contains("full_cell_id") ? to_string(cellj, "full_cell_id") : to_string(cellj, "cid"));
        celldev->set_arfcn(channel);
        celldev->set_pci(to_string(cellj, "pci"));
        celldev->set_rssi(fmt::format("{}", rssi));
        celldev->set_rsrp(fmt::format("{}", rsrp));
        celldev->set_rsrq(fmt::format("{}", rsrq));
        if (band_val)
            celldev->set_band(fmt::format("{}", *band_val));
        else
            celldev->set_band(to_string(cellj, "band"));

        // Compute DL/UL if missing
        std::optional<double> dl_freq, ul_freq;
        if (earfcn_val && band_val) {
            auto bi = lte_bands.find(*band_val);
            if (bi != lte_bands.end()) {
                const auto& info = bi->second;
                dl_freq = info.fdl_low + 0.1 * (*earfcn_val - info.n_offs);
                if (info.ful_low)
                    ul_freq = *(info.ful_low) + 0.1 * (*earfcn_val - info.n_offs);
            }
        }

        // Add all primitive fields as cell.* tags for UI display (top-level + chosen cell)
        auto tags = in_pack->fetch_or_add<kis_devicetag_packetinfo>(cell->pack_comp_devicetag);
        tags->tagmap["cell.full_composite"] = composite_id;
        if (band_val)
            tags->tagmap["cell.band"] = fmt::format("{}", *band_val);
        if (dl_freq)
            tags->tagmap["cell.dl_freq_mhz"] = fmt::format("{:.3f}", *dl_freq);
        if (ul_freq)
            tags->tagmap["cell.ul_freq_mhz"] = fmt::format("{:.3f}", *ul_freq);
        auto add_tags = [&tags, &to_string](const nlohmann::json& obj) {
            for (auto it = obj.begin(); it != obj.end(); ++it) {
                if (it.value().is_null())
                    continue;
                if (it.value().is_primitive()) {
                    auto key = std::string("cell.") + it.key();
                    // Don't overwrite computed values
                    if (tags->tagmap.find(key) == tags->tagmap.end()) {
                        auto sval = to_string(obj, it.key());
                        if (!sval.empty())
                            tags->tagmap[key] = sval;
                    }
                }
            }
        };
        add_tags(j);
        add_tags(cellj);

        // Log meta copy
        auto meta = in_pack->fetch<packet_metablob>(cell->pack_comp_meta);
        if (meta == nullptr) {
            meta = std::make_shared<packet_metablob>("cell", json->json_string);
            in_pack->insert(cell->pack_comp_meta, meta);
        }

        return 1;
    }

private:
    std::shared_ptr<packet_chain> packetchain;
    std::shared_ptr<entry_tracker> entrytracker;
    std::shared_ptr<device_tracker> devicetracker;

    int pack_comp_common = -1;
    int pack_comp_json = -1;
    int pack_comp_meta = -1;
    int pack_comp_radiodata = -1;
    int pack_comp_gps = -1;
    int pack_comp_devicetag = -1;

    int cell_common_id = -1;
};

class datasource_cell_builder : public kis_datasource_builder {
public:
    datasource_cell_builder() :
        kis_datasource_builder() {
        register_fields();
        reserve_fields(NULL);
        initialize();
    }

    datasource_cell_builder(int in_id) :
        kis_datasource_builder(in_id) {
        register_fields();
        reserve_fields(NULL);
        initialize();
    }

    datasource_cell_builder(int in_id, std::shared_ptr<tracker_element_map> e) :
        kis_datasource_builder(in_id, e) {
        register_fields();
        reserve_fields(e);
        initialize();
    }

    virtual ~datasource_cell_builder() { }

    virtual shared_datasource build_datasource(shared_datasource_builder in_sh_this) override {
        return shared_datasource(new kis_datasource_cell(in_sh_this));
    }

    virtual void initialize() override {
        set_source_type("cell");
        set_source_description("Android cell JSON stream");

        set_probe_capable(true);
        set_list_capable(false);
        set_local_capable(true);
        set_remote_capable(true);
        // Active external capture; we must launch the helper binary, so this is not passive.
        set_passive_capable(false);

        set_tune_capable(false);
        set_hop_capable(false);
    }
};

extern "C" {
    int kis_plugin_version_check(struct plugin_server_info *si) {
        si->plugin_api_version = KIS_PLUGINTRACKER_VERSION;
        si->kismet_major = VERSION_MAJOR;
        si->kismet_minor = VERSION_MINOR;
        si->kismet_tiny = VERSION_TINY;
        return 1;
    }

    int kis_plugin_activate(global_registry *in_globalreg) {
        try {
            auto dst = Globalreg::fetch_mandatory_global_as<datasource_tracker>();
            dst->register_datasource(shared_datasource_builder(new datasource_cell_builder()));
            _MSG("cell datasource plugin loaded (type=cell, binary=kismet_cap_cell_capture)",
                 MSGFLAG_INFO);

            // If sources= were parsed before this plugin loaded, re-launch any configured
            // cell sources now that the driver exists.
            auto cfg_sources = in_globalreg->kismet_config->fetch_opt_vec("source");
            for (const auto& s : cfg_sources) {
                // Match definitions starting with "cell:" or "cell," etc.
                if (str_lower(s).rfind("cell", 0) == 0) {
                    dst->open_datasource(s,
                        [s](bool success, std::string reason, shared_datasource) {
                            if (success) {
                                _MSG(std::string("cell datasource '") + s +
                                     "' launched (deferred)", MSGFLAG_INFO);
                            } else {
                                _MSG(std::string("cell datasource '") + s +
                         "' failed (deferred): " + reason, MSGFLAG_ERROR);
                            }
                        });
                }
            }

            // Register the cell PHY so JSON frames get turned into devices
            auto devicetracker = Globalreg::fetch_mandatory_global_as<device_tracker>();
            devicetracker->register_phy_handler(dynamic_cast<kis_phy_handler *>(new kis_cell_phy(0)));

            // Register UI module to render cell fields in the device details panel
            auto httpregistry = Globalreg::fetch_mandatory_global_as<kis_httpd_registry>();
            // Served from plugin/cell/httpd/js/ relative to plugin install
            httpregistry->register_js_module("kismet_ui_cell", "plugin/cell/js/kismet.ui.cell.js");
            return 1;
        } catch (const std::exception &e) {
            _MSG(std::string("cell datasource plugin failed: ") + e.what(), MSGFLAG_ERROR);
            return -1;
        }
    }

    int kis_plugin_finalize(global_registry *in_globalreg) {
        return 1;
    }
}
#include <fmt.h>
#include <nlohmann/json.hpp>
#include <sys/time.h>
