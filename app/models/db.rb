# coding: utf-8
#
# MIT License
#
# Copyright (c) 2016-2017 Vladimir Lebedev-Schmidthof
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

require 'base64'

class Db < ActiveRecord::Base
    
    def self.checkCredentials(id, hash)
        rows = connection.select_all(%Q{select hash, status from "user" where name = #{sanitize(id)}})
        if (rows.to_ary().size != 1)
            return nil
        end

        server_hash = rows[0]["hash"] # that's h(h(p + N + l) + l)
        if hash == server_hash
            if rows[0]["status"] == 'A'
                return 'A'
            else
                return 'U'
            end
        else
            return nil
        end
    end

    def self.addUser(oldid, id, hash)
        transaction do
            rows = connection.select_all(%Q{select hash from "user" where name = #{sanitize(oldid)}})
            
            calc_hash = Digest::SHA2.hexdigest(hash + id)
            
            if rows.to_ary.size > 0
                connection.update(%Q{update "user" set hash = #{sanitize(hash)}, name = #{sanitize(id)} where name = #{sanitize(oldid)}})
            else
                connection.insert(%Q{insert into "user" (name, hash) values (#{sanitize(id)}, #{sanitize(hash)})})
            end
        end
    end

    def self.getAllUsers()
        rows = connection.select_all(%Q{select name, status from "user" order by name asc})
        return rows
    end

    def self.getUser(name)
        rows = connection.select_all(%Q{select name, status from "user" where name = #{sanitize(name)}})
        ret = nil
        if rows.to_ary.size == 1
            ret = rows[0]
        end
        return ret
    end

    def self.getAllKnownDevices()
        sql = "select device.id, device.hw_id, device.name, extract(epoch from di1.dt) as ping_dt, extract(epoch from di2.dt) as point_dt from device left outer join device_info di1 on device.name is not null and device.id=di1.dev_id and di1.key='last_ping' left outer join device_info di2 on device.name is not null and device.id=di2.dev_id and di2.key='last_point'"
        rows = connection.select_all(sql)
        return rows
    end

    def self.getAllUnknownDevices()
        rows = connection.select_all(%Q{select id from device where name is null order by id asc})
        return rows
    end

    def self.getDevice(id)
        rows = connection.select_all(%Q{select id, hw_id, name, description from device where id = #{sanitize(id)}})
        ret = nil
        if rows.to_ary.size == 1
            ret = rows[0]
        end
        return ret
    end

    def self.getDeviceByHwId(hw_id)
        rows = connection.select_all(%Q{select id, name, description from device where hw_id = #{sanitize(hw_id)}})
        ret = nil
        if rows.to_ary.size == 1
            ret = rows[0]
        end
        return ret
    end

    def self.addDevice(id, hw_id, name, desc)
        transaction do
            connection.insert(%Q{insert into device (id, hw_id, name, description) values (#{sanitize(id)},#{sanitize(hw_id)}, #{sanitize(name)}, #{sanitize(desc)})})
        end
    end

    def self.editDevice(id, name)
        connection.update(%Q{update device set name = #{name.nil? ? "NULL": sanitize(name)} where id = #{sanitize(id)}})
    end

    def self.mapImage()
        rows = connection.select_all(%Q{select map, content_type from map})
        ret = nil
        if rows.to_ary.size == 1
            encoded = rows[0]["map"]
            coded = ActiveRecord::Base.connection.unescape_bytea(encoded)
            ret = {:map => Base64.decode64(coded), :content_type => rows[0]["content_type"]}
        end
        return ret
    end

    def self.mapCoords()
        rows = connection.select_all(%Q{select latitude, longitude from map})
        ret = nil
        if rows.to_ary.size == 1
            ret = rows[0]
        end
        return ret
    end

    def self.setMap(raw, content_type, longitude, latitude)
        transaction do
            fields = {}
            if not raw.nil?
                coded = Base64.encode64(raw)
                encoded = ActiveRecord::Base.connection.escape_bytea(coded)
                fields["map"] = sanitize(encoded)
            end
            if not content_type.nil?
                fields["content_type"] = sanitize(content_type)
            end
            if longitude != 0 and latitude != 0
                fields["longitude"] = sanitize(longitude)
                fields["latitude"] = sanitize(latitude)
            end
            
            dbcoords = mapCoords()
            if dbcoords.nil?
                connection.insert(%Q{insert into map (} + fields.keys.join(', ') + %Q{) values (} + fields.values.join(', ') + %Q{)})
            else
                connection.update(%Q{update map set } + fields.map {|k,v| k + ' = ' + v}.join(', '))
            end
        end
    end

    def self.points(ids, time)
        clauses = []
        if not ids.nil? and ids.length > 0
            clauses.push('device_id in (' + ids.map{|i| "'"+i+"'"}.join(', ') + ')')
        end
        if time > 0
            clauses.push('dt > to_timestamp(' + time.to_s + ')')
        end
        sql = 'select device_id, EXTRACT(epoch FROM dt) as dt, latitude, longitude from point'
        if not clauses.empty?
            sql = sql + ' where ' + clauses.join(' and ')
        end
        sql += ' order by device_id asc, dt asc'

        rows = connection.select_all(sql)
        ret = {}
        for row in rows
            dev_id = row["device_id"]
            if ret[dev_id].nil?
                ret[dev_id] = {}
            end
            ret[dev_id][Float(row['dt'])] = {"lat" => Float(row['latitude']), "lon" => Float(row['longitude'])}
        end
        return ret
    end

    def self.addDeviceMsg(id, desc, type, msg, t)
        repeat = true
        while repeat
            begin
                connection.insert("insert into device_ping (device_id, dt_device, msg_type, message) values (#{sanitize(id)}, TIMESTAMP WITHOUT TIME ZONE 'epoch' + #{sanitize(t)} * INTERVAL '1 second', #{sanitize(type)}, #{sanitize(msg)})")
                repeat = false
            rescue ActiveRecord::InvalidForeignKey
                addDevice(id, desc)
            end
        end
    end

    def self.addDeviceData(id, lat, lon, acc, spd, distance, t)
        repeat = true
        while repeat
            begin
                connection.insert("insert into point (device_id, latitude, longitude, accuracy, speed, distance, dt) values (#{sanitize(id)}, #{sanitize(lat)}, #{sanitize(lon)}, #{sanitize(acc)}, #{sanitize(spd)}, #{sanitize(distance)}, TIMESTAMP WITHOUT TIME ZONE 'epoch' + #{sanitize(t)} * INTERVAL '1 second' )")
                repeat = false
            rescue ActiveRecord::InvalidForeignKey
                addDevice(id, nil)
            end
        end
        return true
    end

    def self.getAllParameters(where=nil)
        whereClause = ''
        unless where.nil?
            whereClause = "where " + where
        end
        all_params = connection.select_all("select id, t, name from parameter " + whereClause + " order by id asc")
        res = {}
        for row in all_params
            res[row["id"]] = {"name" => row["name"], "t" => row["t"]}
        end
        return res
    end

    def self.getCommonParameters()
        res = getAllParameters()
        cmds = connection.select_all("select command.id as id, command_data.param_id as param_id, command_data.value as value from command, command_data where command.device_id is NULL and command.id = command_data.id order by command.id desc")

        for row in cmds
            if res.has_key?(row["param_id"]) and not res[row["param_id"]].has_key?("value")
                res[row["param_id"]]["value"] = row["value"]
            end
        end
        return res
    end

    def self.getParametersForDevice(dev_id, id)
        cmds = connection.select_all("select command.id as id, command_data.param_id as param_id, command_data.value as value from command, command_data where command.id > #{sanitize(id)} and (command.device_id = #{sanitize(dev_id)} or command.device_id is null) and command.id = command_data.id order by command.id desc")
        res = getAllParameters()
        max_id = id
        for row in cmds
            row_id = row["id"].to_i
            #puts row_id.class.name
            if row_id > max_id
                max_id = row_id
            end

            if res.has_key?(row["param_id"]) and not res[row["param_id"]].has_key?("value")
                res[row["param_id"]]["value"] = row["value"]
            end
        end
        res["last_command_id"] = max_id

        #puts res

        return res
    end

    def self.writeParams(dev_id, username, params)
        transaction do
            sql = %Q{insert into command (device_id, user_name) values (#{sanitize(dev_id)}, #{sanitize(username)}) returning id}
            cmds = connection.select_all(sql)
            id = cmds[0]['id']

            params.each do |key, value|
                sql= %Q{insert into command_data (id, param_id, value) values (#{id}, #{sanitize(key)}, #{sanitize(value)})}
                connection.insert(sql)
            end

            return id
        end
    end

    def self.useFuelCode(code, dev_id)
        sql = %Q{select dev_id, upg_id, amount from fuel_code where code = #{sanitize(code)}}
        rows = connection.select_all(sql)
        if rows.rows.empty?
            return [-1, nil] # no code
        end
        unless rows[0]['dev_id'].nil?
            return [0, nil] #used code
        end

        upg_id = rows[0]["upg_id"]

#        sql = %Q{select id from device where id=#{sanitize(dev_id)}}
#        rows = connection.select_all(sql)
#        if rows.rows.empty?
#            addDevice(dev_id, nil)
#        end
        sql = %Q{update fuel_code set dev_id = #{sanitize(dev_id)}, dt = now() where code = #{sanitize(code)} and dev_id is null returning amount}
        upds = connection.select_all(sql)

        if upds.rows.empty?
            return [-1, nil]
        else
            upgradeValues = nil
            unless upg_id.nil?
                upgradeValues = getUpgradeValues(upg_id)
            end
            amount = upds[0]['amount']
            return [amount.to_i, nil]
        end
    end

    def self.getAllFuelCodes()
        sql = %Q{select fuel_code.code as code, fuel_code.upg_id as upg_id, fuel_code.amount as amount, fuel_code.dev_id as dev_id, extract(epoch from fuel_code.dt) as dt, device.name  as name from fuel_code left outer join device on fuel_code.dev_id = device.id}
        ret = connection.select_all(sql)
        return ret.to_hash
    end

    def self.addFuelCodes(codes)
        transaction do
            for row in codes
                code = row['code']
                amount = row['amount']
                sql = %Q{insert into fuel_code (code, amount, upg_id) values (#{sanitize(row['code'])}, #{sanitize(row['amount'])}, #{sanitize(row['upg_id'])})}
                connection.insert(sql)
            end
        end
    end

    def self.checkCodeExists(code)
        r = connection.select_all("select code, amount from fuel_code where code = #{sanitize(code.to_s)}")
        return (not r.rows.empty?)
    end

    def self.addDeviceStat(dev_id, t, stat)
        if stat.nil?
            return
        end
        stat.each do |k,v|
            repeat = true
            while repeat
                begin
                    sql = "select count(*) from device_stat where dev_id = #{sanitize(dev_id)} and dt = TIMESTAMP WITHOUT TIME ZONE 'epoch' + (#{sanitize(t)} * INTERVAL '1 second' ) and key = #{sanitize(k)}"
                    rows = connection.select_all(sql)
                    puts 'select returned ' + rows.to_ary.to_s
                    if rows[0]["count"].to_i == 0
                        sql = "insert into device_stat (dev_id, dt, key, value) values (#{sanitize(dev_id)}, TIMESTAMP WITHOUT TIME ZONE 'epoch' + (#{sanitize(t)} * INTERVAL '1 second' ), #{sanitize(k)}, #{sanitize(v)})"
                        connection.insert(sql)
                    end
                    repeat = false
                rescue ActiveRecord::RecordNotUnique
                    repeat = false
                end
            end

            repeat = true
            while repeat
                begin
                    sql = "insert into device_info (dev_id, dt, key, value) values (#{sanitize(dev_id)}, TIMESTAMP WITHOUT TIME ZONE 'epoch' + (#{sanitize(t)} * INTERVAL '1 second' ), #{sanitize('stat_' + k)}, #{sanitize(v)})"
                    connection.execute(sql)
                    repeat = false
                rescue ActiveRecord::InvalidForeignKey
                    addDevice(dev_id, nil)
                rescue ActiveRecord::RecordNotUnique
                    repeat = false
                end
            end
        end
    end

    def self.getLatestDeviceStat(dev_id)
        sql = "select extract(epoch from dt) as dt, key, value from device_stat where (dev_id, dt, key) in (select dev_id, max(dt) as dt, key from device_stat where dev_id = #{sanitize(dev_id)} group by key, dev_id)"
        rows = connection.select_all(sql)
        return rows.to_ary
    end

    def self.setDeviceInfo(dev_id, values)
        transaction do
            for row in values
                sql = "insert into device_info (dev_id, key, value, dt) values (#{sanitize(dev_id)}, #{sanitize(row["key"])}, #{sanitize(row["value"])}, TIMESTAMP WITHOUT TIME ZONE 'epoch' + (#{sanitize(row["dt"])} * INTERVAL '1 second'))"
                connection.execute(sql)
            end
        end
    end

    def self.addDump(dev_id, dt, text)
        sql = "insert into device_dump (dev_id, dt, message) values (#{sanitize(dev_id)}, TIMESTAMP WITHOUT TIME ZONE 'epoch' + (#{sanitize(dt)} * INTERVAL '1 second'), #{sanitize(text)})"
        connection.execute(sql)
    end

    # repair codes
    def self.useRepairCode(code, dev_id)
        sql = %Q{select dev_id, amount from repair_code where code = #{sanitize(code)}}
        rows = connection.select_all(sql)
        if rows.rows.empty?
            return -1 # no code
        end

        unless rows[0]['dev_id'].nil?
            return 0 #used code
        end

        sql = %Q{update repair_code set dev_id = #{sanitize(dev_id)}, dt = now() where code = #{sanitize(code)} and dev_id is null returning amount}
        upds = connection.select_all(sql)

        if upds.rows.empty?
            return -1
        else
            amount = upds[0]['amount']
            return amount.to_i
        end
    end

    #device upgrades

    def self.getUpgradeValues(upg_id)
        sql = %Q{select p.id as param_id, up.value as value from parameter p, upgrade_param up where up.upg_id = #{sanitize(upg_id)} and up.param_id = p.id}
        values = connection.select_all(sql)
        ret = {}
        for v in values
            ret[v["param_id"]] = v["value"]
        end
        return ret
    end

    def self.getDeviceUpgrades(dev_id)
        sql = %Q{select id, description from upgrade where dev_id = #{sanitize(dev_id)} and status = 'A' order by id asc}
        rows = connection.select_all(sql)
        if rows.empty?
            return rows
        end

        for u in rows
            up_id = u["id"]
            values = getUpgradeValues(up_id)
            u["values"] = values
        end

        return rows
    end

    def self.getUpgrade(upg_id)
        sql = %{select dev_id, description from upgrade where id = #{sanitize(upg_id)}}
        rows = connection.select_all(sql)
        if rows.empty?
            return {}
        end
        ret = rows[0]

        values = getUpgradeValues(upg_id)
        ret["values"] = values
        return ret
    end

    def self.editUpgrade(dev_id, upg_id, description, params)
        transaction do
            if upg_id.nil?
                sql = %Q{insert into upgrade (dev_id, description) values (#{sanitize(dev_id)}, #{sanitize(description)}) returning id}
                cmds = connection.select_all(sql)
                upg_id = cmds[0]['id']
            else
                sql = %Q{update upgrade set dt = now(), description = #{sanitize(description)} where id = #{sanitize(upg_id)}}
                cmds = connection.execute(sql)
            end
            
            sql = %Q{delete from upgrade_param where upg_id = #{sanitize(upg_id)}}
            connection.execute(sql)

            for p in params.keys
                sql = %Q{insert into upgrade_param (upg_id, param_id, value) values (#{sanitize(upg_id)}, #{sanitize(p)}, #{sanitize(params[p])})}
                connection.execute(sql)
            end
        end
    end

    def self.upgradeDelete(upg_id)
        sql = %Q{update upgrade set status = 'D', dt = now() where id = #{sanitize(upg_id)}}
        connection.execute(sql)
    end

    def self.getDeviceUpgradesRaw(dev_id, dt)
        sql = %{select id, extract(epoch from dt) as dt from upgrade where dev_id = #{sanitize(dev_id)} and dt > TIMESTAMP WITHOUT TIME ZONE 'epoch' + #{sanitize(dt)} * INTERVAL '1 second' and status = 'A'}
        rows = connection.select_all(sql)
        ret = {}

        maxDt = 0
        for r in rows
            upg_id = r["id"]
            values = getUpgradeValues(upg_id)
            
            ret[r["id"]] = values

            dt = r["dt"].to_i
            if maxDt < dt
                maxDt = dt + 1
            end
        end
        if maxDt > 0
            ret["time"] = maxDt
            return ret
        end
        return nil
    end

    def self.getDeviceTracksSeparated(dev_id)
        # first, read all start/stop markers from device_stat
        sql = %Q{select extract(epoch from dt) as dt from device_stat where dev_id = #{sanitize(dev_id)} and key in ('mark_start', 'mark_stop')}
        markers = connection.select_all(sql)

        ret = []

        time0 = 0
        for marker in markers
            t = marker["dt"].to_f
            sql = %Q{select latitude, longitude from point where device_id = #{sanitize(dev_id)} and dt between (TIMESTAMP WITHOUT TIME ZONE 'epoch' + #{sanitize(time0)} * INTERVAL '1 second') and (TIMESTAMP WITHOUT TIME ZONE 'epoch' + #{sanitize(t)} * INTERVAL '1 second') order by dt asc}
            points = connection.select_all(sql)

            unless points.empty?
                if time0 == 0
                    name = '...-' + Time.at(t).to_s
                else
                    name = Time.at(time0).to_s + "..." + Time.at(t).to_s
                end
                
                track = []
                for p in points
                    track.push([p["latitude"], p["longitude"]])
                end
                
                ret.push({"name" => name, "track" => track})
            end

            time0 = t
        end

        return ret
    end


#======================================================
# CHAT
# =====================================================
    def self.getChatLogSince(id)
        sql = %Q{select id, message from chat_log where id >= #{sanitize(id)} order by id asc}
        rows = connection.select_all(sql)

        return rows
    end

    def self.addChatMessage(msg)
        sql = %Q{insert into chat_log (message) values (#{sanitize(msg)}) returning id}
        rows = connection.select_all(sql)
        return rows[0]["id"]
    end
end

