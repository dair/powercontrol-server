# coding: utf-8

class DeviceController < ApplicationController
    skip_before_filter :verify_authenticity_token, :only => [:p]

    def f0(l)
        ret = 0.0
        begin
            if l
                ret = Float(l)
            end
        rescue ArgumentError
            ret = 0.0
        end
        return ret
    end

    def addP(params)
        res = {'code' => 1}

        if params['id'].nil?
            res['code'] = 0
            res['error'] = 'No id'
            return res
        end
        id = params['id']
        
        dt = id0(params["t"])
        if dt == 0
            dt = Time.now.to_i
        end

        lat = f0(params["lat"])
        lon = f0(params["lon"])
        spd = f0(params["spd"])
        distance = f0(params["l"])

        code = Db.addDeviceData(id, lat, lon, spd, distance, dt)
        Db.setDeviceInfo(id, [{'key' => 'last_point', 'value' => (lat.to_s + ',' + lon.to_s), 'dt' => dt}])
        if not code
            res['code'] = 0
        end

        res['id'] = 2
        res['timeout'] = 42;
        return res
    end

    def p
        res = { "code" => 0 }

        if params.has_key?("id")
            dev_id = params["id"]
            if params.has_key?("type")
                type = params["type"]
                if type == "marker"
                    res["code"] = 1
                    t = params["t"].to_i
                    marker = params["m"]
                    unless marker.nil?
                        Db.addDeviceStat(dev_id, t, {('mark_' + marker) => ''})
                    end
                elsif type == "ping"
                    t = params["t"].to_i
                    
                    desc = nil
                    if params.has_key?("desc")
                        desc = params["has_key"]
                    end

                    Db.addDeviceMsg(dev_id, desc, 'P', nil, t)
                    Db.setDeviceInfo(dev_id, [{'key' => 'last_ping', 'value' => '', 'dt' => t}])

                    p = params["device"].clone
                    p.delete("type")
                    p.delete("c")
                    p.delete("t")
                    p.delete("id")

                    unless p.empty?
                        p["ip"] = request.remote_ip
                        Db.addDeviceStat(dev_id, t, p)
                    end

                    res["code"] = 1
                elsif type == "loc"
                    res = addP(params)
                elsif type == "code"
                    amount = Db.useFuelCode(params['code'], dev_id)
                    res["code"] = 1
                    res["id"] = -1
                    res["fuel_code"] = {"amount" => amount, "code" => params['code']}
                end
            end

            if params.has_key?("c")
                cmds = Db.getParametersForDevice(dev_id, params["c"].to_i)
                cmd_id = cmds["cmd_id"]
                cmds.delete("cmd_id")
                c = {}
                cmds.each do |k,v|
                    if v.has_key?("value") and not v["value"].nil?
                        c[k] = v["value"]
                    end
                end
                res = c.merge(res)
                if not c.empty?
                    res["id"] = cmd_id
                end
            end
        end

        #puts "Returning: " + res.to_s
        render :json => res
    end

    def fuel
        #entering fuel code
        res_code = false
        amount = 0
        if params.has_key?('dev_id') and params.has_key?('code')
            amount = Db.useFuelCode(params['code'])
            if amount >= 0
                res_code = true
            end
        end
        res = {'code' => res_code, 'amount' => amount}
        render :json => res
    end

    def auth
        dev_id = params["id"]
        dev_desc = params["desc"]
        ret = {}
        ret["code"] = false
        unless dev_id.nil?
            dev = Db.getDevice(dev_id)
            if dev.nil?
                Db.addDevice(dev_id, dev_desc)
                ret["code"] = false
            else
                if dev["type"].nil?
                    ret["code"] = false
                else
                    ret["code"] = true
                    ret["a"] = form_authenticity_token
                end
            end
        end

        #puts ret

        render :json => ret
    end
end
