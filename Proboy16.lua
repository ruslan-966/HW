-- ************************ параметры ****************************
--выбор эмитента
local s_classcode="QJSIM" 
local s_seccode="SBER"
--счета
local s_account="SPBFUT00M61"  
local s_clientCode = ""
local s_depoaccount = ""

local n_amnt = 1
local n_timeframe = 60						
local n_controlvalue = 5				
local n_deltacandle = 100						
local s_ordertype = "MARKET" 			--"LIMIT" - лимитный, "MARKET" - по рынку
local s_typesize = "LONG"			--"LONG" - Лонг; "SHORT" - Шорт; "REVERS" - Реверс		
--Выбор рынка для торговли								
local s_whatismarket = "FUNDS"  	-- "FUTURES" - Срочный, "FUNDS" - Фондовый									
local s_demomode = "YES"
local s_settlementmode = "T2"

--local s_name_of_file = "source_data_file.txt"
local s_log_file_name = "\\log.txt"				--на перспективу
local s_path_to_file = getScriptPath()			--на перспективу
local s_name_fale_control = "\\control_begin_file.txt"
local s_path_file_contr_beg = getScriptPath()..s_name_fale_control

--переменные программы
local t_ds
local s_error_desc
local n_trans_id =os.time()
local n_LastStatus    = nil         -- Последний статус транзакции, который был выведен в сообщении
local n_NumbOfNewOrd  = nil			-- Номер нового ордера, занесенного в таблицу оредеров
local t_OrderNew  					--Таблица, содержащая информацию по новому ордеру
local n_OpenPozCur = 0
local b_isQuoteComeIn = false
local ep_List_Cand = {}
local ep_preList_Cand = {}
local s_time_str = ""

--local id

function f_takeparamfromstring(par, str, p)										--возвращает значение параметра в виде строки, на входе две строки: параметр и исходная строка
	local n_par_enter = str:find(par)
	if n_par_enter == nil then return nil end
	local n_vk_enter = str:find("\n",n_par_enter)
	if n_vk_enter == nil then n_vk_enter = #str end
	local s_work_string =  string.sub (str, n_par_enter, n_vk_enter)
	n_par_enter = s_work_string:find(":")
	s_work_string = string.sub(s_work_string, n_par_enter)
	if p ~= nil then
		return string.match(s_work_string, '%d[%d.,]*')
	else
		return s_work_string:gsub('%W','')
	end
end

b_is_run=true

function OnOrder(order)															-- Вызывается терминалом, когда приходит информация о заявке
	if order.trans_id == n_trans_id then
		t_OrderNew = order
	end
end

function OnTransReply(trans_reply)												-- Функция вызывается терминалом, когда с сервера приходит новая информация о транзакциях
   -- Если пришла информация по нашей транзакции
   if trans_reply.trans_id == n_trans_id then
      -- Если данный статус уже был обработан, выходит из функции, иначе запоминает статус, чтобы не обрабатывать его повторно
      if trans_reply.status == n_LastStatus then return else n_LastStatus = trans_reply.status end
      -- Выводит в сообщении статусы выполнения транзакции
      if       trans_reply.status <  2    then 
         -- Статусы меньше 2 являются промежуточными (0 - транзакция отправлена серверу, 1 - транзакция получена на сервер QUIK от клиента),
         -- при появлении такого статуса делать ничего не нужно, а ждать появления значащего статуса
         -- Выходит из функции
         return
      elseif   trans_reply.status == 3    then -- транзакция выполнена
        local str = 'OnTransReply(): По транзакции №'..trans_reply.trans_id..' УСПЕШНО ВЫСТАВЛЕНА заявка №'..trans_reply.order_num..' по цене '..trans_reply.price..' объемом '..trans_reply.quantity..'\n' 
		message(str)
		f_WLOG(str)
	  elseif   trans_reply.status >  3    then -- произошла ошибка
        local str = 'OnTransReply(): ОШИБКА выставления заявки по транзакции №'..trans_reply.trans_id..', текст ошибки: '..trans_reply.result_msg..'\n'
		message(str)
		f_WLOG(str)		
      end
   end
end

local function toPrice(security,value,class)									--Преобразует цену для бумаги и инструмента к правильному виду, возвращает строку
	-- преобразования значения value к цене инструмента правильного ФОРМАТА (обрезаем лишние знаки после разделителя, проверяем кратность)
	-- Возвращает строку
	if (security==nil or value==nil) then return nil end
	local scale=getSecurityInfo(class or getSecurityInfo("",security).class_code,security).scale
	local stepvalue = getSecurityInfo(class or getSecurityInfo("",security).class_code,security).min_price_step
	if stepvalue >= 1 then  --убираем точку в конце цены
		return string.gsub(string.format("%."..string.format("%d",scale).."f",tonumber(value) - tonumber(value) % stepvalue), "%.", "")
	else					--оставляем цену с точкой
		return string.format("%."..string.format("%d",scale).."f",tonumber(value) - tonumber(value) % stepvalue)
	end
end

function f_ordering_candles()													--Функция заказывает свечи М1
	local n_try_count
	local n1
---[[ заказываем свечи
	t_ds, s_error_desc = CreateDataSource(s_classcode, s_seccode, INTERVAL_M1)
	if t_ds == nil then 
		local str = "Ошибка в исходных данных. Непроавильно указан код класса или тикер инструмента.\nПрограмма остановлена.\n"
		message(str)
		f_WLOG(str)
		stop_script()
	end
		-- Ограничиваем количество попыток (времени) ожидания получения данных от сервера
	n_try_count = 0
	while t_ds:Size() == 0 
		and n_try_count < 1000 
		and s_error_desc == nil do
		sleep(100)
		n_try_count = n_try_count + 1
	end
		-- Если от сервера пришла ошибка, то выведем ее и прерываем выполнение скрипта
	if s_error_desc ~= nil and s_error_desc ~= "" then
		local str = "Ошибка получения таблицы свечей для инструмента: " ..s_seccode..'.\n Сообщение: '.. s_error_desc..'\n'
		message(str)
		f_WLOG(str)
		stop_script()
	end
	--t_ds:SetUpdateCallback(f_cb)
	n1 = t_ds:Size()			
	if n1 < n_timeframe*2 then 
		local str = "Количество данных по инструменту недостаточно, что бы продолжить работу.\nПрограмма остановлена.\nЗапустите скрипт несколько позже.\n"
		message(str)
		f_WLOG(str)
		stop_script()
	end
	--]]
end

local function f_IsDelayExist()													--Функция отлавливает критическое падение интернета во время нахождения робота во включенном состоянии
---[[
	local b_was_disconnect = false
	local b_was_delay = false
	::beginning::
	while isConnected()~=1 and b_is_run do	--обработка отсутствия соединения
		b_was_disconnect = true
		b_was_delay = true
		sleep(1000)
		PrintDbgStr("point 03 Отсутствует связь по интернету") 
	end	
	if b_is_run ~= true then goto ending end
	if b_was_disconnect and b_is_run then 
		sleep(300*1000) 
		b_was_disconnect = false
		goto beginning
	end
	::ending::
	return b_was_delay
end

local function f_what_time_to_begin(cl_cd)
	if cl_cd == nil then return nil end
	local tm = os.date("!*t",os.time())
	tm.min = 0
	tm.sec = 0
	if cl_cd == "QJSIM"  or cl_cd =="TQBR" then
		tm.hour = 10
	elseif cl_cd == "SPBFUT" then
		tm.hour = 7
	else
		tm = nil
	end
	return tm 
end

local function f_what_time_to_finish(cl_cd)
	if cl_cd == nil then return nil end
	local tm = os.date("!*t",os.time())
	tm.hour = 23
	tm.min = 49
	tm.sec = 59
	return tm 
end

local function f_what_lunch_time_to_finish(cl_cd)
	if cl_cd == nil then return nil end
	local tm = os.date("!*t",os.time())
	tm.hour = 14
	tm.min = 04
	tm.sec = 59
	return tm
end	

local function f_what_lunch_time_to_begin(cl_cd)
	if cl_cd == nil then return nil end
	local tm = os.date("!*t",os.time())
	tm.hour = 14
	tm.min = 0
	tm.sec = 0
	return tm
end	

local function f_what_dinner_time_to_begin(cl_cd)
	if cl_cd == nil then return nil end
	local tm = os.date("!*t",os.time())
	tm.hour = 18
	tm.min = 40
	tm.sec = 0
	return tm
end	

local function f_what_dinner_time_to_finish(cl_cd)
	if cl_cd == nil then return nil end
	local tm = os.date("!*t",os.time())
	tm.hour = 19
	tm.min = 04
	tm.sec = 59
	return tm
end	

local function offset()
   local currenttime = os.time()
   local datetime = os.date("!*t",currenttime)
   return currenttime - os.time(datetime)
end
local offset = offset()


local function f_what_base_time()
	local tm = os.date("!*t",os.time()+ offset)
	tm.hour = 0
	tm.min = 0
	tm.sec = 0
	return tm
end

local function f_All_in_epoch(cl_cd)
	local t_tb = f_what_time_to_begin(cl_cd)
	local n_ep_t_beg = os.time(t_tb)
	t_tb = f_what_time_to_finish(cl_cd)
	local n_ep_t_fin = os.time(t_tb)

	t_tb = f_what_lunch_time_to_begin(cl_cd)
	local n_ep_t_l_beg = os.time(t_tb)
	t_tb = f_what_lunch_time_to_finish(cl_cd)
	local n_ep_t_l_fin = os.time(t_tb)

	t_tb = f_what_dinner_time_to_begin(cl_cd)
	local n_ep_t_d_beg = os.time(t_tb)
	t_tb = f_what_dinner_time_to_finish(cl_cd)
	local n_ep_t_d_fin = os.time(t_tb)
	t_tb = f_what_base_time()
	local n_ep_base_time = os.time(t_tb)
	return n_ep_base_time,n_ep_t_beg, n_ep_t_fin, n_ep_t_l_beg, n_ep_t_l_fin, n_ep_t_d_beg, n_ep_t_d_fin
end

local function f_ListCandlesCreator(n_TimeCandleSec)
	local n_sec_in_day = 24*60*60
	local n = t_ds:Size()
	local c_d = t_ds:T(n)
	local b_d = {year, month, day, hour, min, sec}
	local pre_base_dat = {year, month, day, hour, min, sec}
	b_d.year = c_d.year
	b_d.month = c_d.month
	b_d.day = c_d.day
	b_d.hour = 0
	b_d.min = 0
	b_d.sec = 0
	local b_t = os.time(b_d)
	for i = 0, n_sec_in_day/n_TimeCandleSec - 1, 1 do
		ep_List_Cand[i] ={beg, fin} 
		ep_List_Cand[i].beg = b_t + i * n_TimeCandleSec
		ep_List_Cand[i].fin = b_t + i * n_TimeCandleSec + n_TimeCandleSec - 1
	end
	
	--находим базовую торговую дату за предыдущий день:
	local cur_dat = {year, month, day}		--текущая торговая дата
	cur_dat.year = t_ds:T(n).year
	cur_dat.month = t_ds:T(n).month
	cur_dat.day = t_ds:T(n).day
	for i = n, 0, -1 do
		if t_ds:T(i).day ~= cur_dat.day then
			local tt = t_ds:T(i)
			pre_base_dat.year = tt.year		--базовая дата за предыдущий торговый день
			pre_base_dat.month = tt.month
			pre_base_dat.day = tt.day
			pre_base_dat.hour = 0
			pre_base_dat.min = 0
			pre_base_dat.sec = 0
			break
		end
	end
	local preb_t = os.time(pre_base_dat)		--перевернули базовую дату предыдущего торгового дня в epo
	for i = 0, n_sec_in_day/n_TimeCandleSec, 1 do				--сформировали перечень свечей за предыдущий торговый день в epo
		ep_preList_Cand[i] ={beg, fin} 
		ep_preList_Cand[i].beg = preb_t + i * n_TimeCandleSec
		ep_preList_Cand[i].fin = preb_t + i * n_TimeCandleSec + n_TimeCandleSec - 1
	end
	return		
end
---[[оходят ли какие то котировки до Quik через OnQuote
function OnQuote(class, sec )							--доходят ли какие то котировки до Quik
	b_isQuoteComeIn = true
end
--]]

function OnAllTrade(alltrade)							--доходят ли какие то сделки до Quik через OnAllTrade
	b_isQuoteComeIn = true
end



local function f_NumCurCandle()							--определяем номер текущей свечи
	local cur_time = os.time()
	for i,val in ipairs(ep_List_Cand) do	
		if cur_time>=val.beg and cur_time<=val.fin then
			return i
		end
	end
	return 0
end

local function f_PrelastCandleFinder()
	local cur_time = os.time()
	local n_cand_num_cur = 0
	local H = 0
	local L = 10000000000
	local V = 0
	local T0 
	n_cand_num_cur = f_NumCurCandle()		--определяем номер текущей свечи
	--определяем Н, L and V предпоследней сформированой свечи
	--находм предпоследнюю свечу с ненулевым объемом
	local b_isCanFinded = false
	local n = t_ds:Size()
	for i = (n_cand_num_cur - 1), 0, -1 do 
		for j = n, 0, -1 do
			local n_tc = os.time(t_ds:T(j))
			if (n_tc >=ep_List_Cand[i].beg) 
				and (n_tc<=ep_List_Cand[i].fin) 
				and (n_tc >= ep_List_Cand[0].beg) then	
				V = V + t_ds:V(j)
				if H < t_ds:H(j) then H = t_ds:H(j) end
				if L > t_ds:L(j) then L = t_ds:L(j) end
			end
			if os.time(t_ds:T(j))< ep_List_Cand[i].beg then break end
		end
		if V > 0 then 
			T0 = ep_List_Cand[i].beg
			break 
		end
	end
	--если объем нулевой, то ищет предпоследнюю свечу в предыдущем дне
	if V == 0 then
		for i = #ep_preList_Cand - 1, 0, -1 do
			for j = n, 0, -1 do
				if (os.time(t_ds:T(j))>=ep_preList_Cand[i].beg) and (os.time(t_ds:T(j))<=ep_preList_Cand[i].fin) then
					V = V + t_ds:V(j)
					if H < t_ds:H(j) then H = t_ds:H(j) end
					if L > t_ds:L(j) then L = t_ds:L(j) end
				end
				if os.time(t_ds:T(j))< ep_preList_Cand[i].beg then break end
			end
			if V > 0 then 
				T0 = ep_preList_Cand[i].beg
				break 
			end
		end
	end
	return H,L,V,T0
end

local function f_FreshBaseData(s_path_file_param)		--Обновляет исходные данные робота из файла
	local S = f_GetValueFromFile(s_path_file_param)		
	--вытаскиваем из строки параметры модели
	s_classcode = f_takeparamfromstring("classcode", S) or s_classcode
	s_seccode = f_takeparamfromstring("seccode", S) or s_seccode
	s_account=f_takeparamfromstring("account", S) or s_account 
	s_clientCode = f_takeparamfromstring("clientCode", S) or s_clientCode
	s_depoaccount = f_takeparamfromstring("depoaccount", S) or s_depoaccount
	n_amnt = tonumber(f_takeparamfromstring("amnt", S, "n")) or n_amnt
	n_timeframe = f_takeparamfromstring("timeframe", S, "n") or n_timeframe	
	local n = f_takeparamfromstring("controlvalue", S, "n")	
	n_controlvalue = tonumber(n) or n_controlvalue
	n_deltacandle = tonumber(f_takeparamfromstring("deltacandle", S, "n")) or n_deltacandle
	s_ordertype =  f_takeparamfromstring("ordertype", S) or s_ordertype 
	s_typesize = f_takeparamfromstring("typesize", S) or s_typesize		
	s_whatismarket = f_takeparamfromstring("whatismarket", S) or s_whatismarket							
	s_demomode = f_takeparamfromstring("demomode", S) or s_demomode
	s_settlementmode = f_takeparamfromstring("settlementmode", S) or s_settlementmode
	local str = "s_classcode = "..s_classcode..
				"\ns_seccode = "..s_seccode..
				"\ns_account = "..s_account.. 
				"\ns_clientCode = "..s_clientCode..
				"\ns_depoaccount = "..s_depoaccount..
				"\nn_amnt = "..tostring(n_amnt)..
				"\nn_timeframe = "..n_timeframe..						
				"\nn_controlvalue = "..tostring(n_controlvalue)..				
				"\nn_deltacandle = "..tostring(n_deltacandle)..
				"\ns_ordertype = "..s_ordertype.. 
				"\ns_typesize = "..s_typesize..		
				"\ns_whatismarket = "..s_whatismarket..							
				"\ns_demomode = "..s_demomode..
				"\ns_settlementmode = "..s_settlementmode
	message (str)
	f_WLOG(str)
end

function f_table_creator()
	-- Создаем новую переменную
	QTable ={}
	QTable.__index = QTable
	-- Функция инициализации таблицы
	function QTable.new()
		local t_id = AllocTable()
		if t_id ~= nil then
			q_table = {}
			setmetatable(q_table, QTable)
			q_table.t_id=t_id
			q_table.caption = ""
			q_table.created = false
			q_table.curr_col=0
			-- Таблица с описанием параметров столбцов
			q_table.columns={}
			return q_table
		else
			return nil
		end
	end
	test_table = QTable:new()
	tt = test_table.t_id
    AddColumn(tt, 1, 'Серверное время', true, QTABLE_STRING_TYPE, 23)
    AddColumn(tt, 2, 'Режим торговли', true, QTABLE_STRING_TYPE, 22)
    AddColumn(tt, 3, 'Текущая цена', true, QTABLE_STRING_TYPE, 20)
	AddColumn(tt, 4, 'Цена max уровня', true, QTABLE_STRING_TYPE, 21)
	AddColumn(tt, 5, 'Цена min уровня', true, QTABLE_STRING_TYPE, 21)
	AddColumn(tt, 6, 'Цена StopLoss', true, QTABLE_STRING_TYPE, 22)
    -- Создаем окно с таблицей
    CreateWindow(tt)
    -- Присваиваем окну заголовок
    SetWindowCaption(tt, "Робот Proboy")
    -- Задаем позицию окна
    SetWindowPos(tt, 0, 70, 698, 90)
	local num = InsertRow(tt, -1)
end

local function f_split_string(inputstr, sep)			--разделяет строку символов по сепаратору
    if sep == nil then
        sep = "%s"
    end
    local t={} ; i=1
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        t[i] = str
        i = i + 1
    end
    return t
end

local function f_SetTimeInCell()
	local loctime = os.date("%H : %M : %S",os.time())
	if s_time_str ~= loctime then
		s_time_str = loctime
		SetCell(tt, 1, 1, loctime)
	end
end

function main()
	--программа вывода таблицы для корректировки исходных данных
	message("Робот Proboy запущен.\nИдет инициализация параметров (2 минуты).")
	sleep(2 * 60 * 1000)

	local s_path = getScriptPath().."\\"
	local s_name_file_param = "\\source_data_file.txt"
	local s_name_file_key = "\\key_file.txt"
	local s_name_fale_cur_param = "\\cur_source_data_file.txt"
	local s_path_file_param = getScriptPath()..s_name_file_param
	local s_path_file_key = getScriptPath()..s_name_file_key	
	local s_path_file_cur_par = getScriptPath()..s_name_fale_cur_param
	
	local b_isNewInf = true
	
	local k = f_GetValueFromFile(s_path_file_contr_beg)
	if k ~= "cont" then
		local f_key = io.open(s_path_file_key,"r+");
		-- Если файл существует: удаляем его
		if f_key ~= nil then 
			f_key:close()
			sleep (200)
			os.remove(s_path_file_key)
		end
    
		local s_command = '"start ProboyV16 "'..s_path	
		os.execute (s_command)
		repeat
			sleep (200)
			f_key = io.open(s_path_file_key,"r+")
		until (f_key ~= nil) or (b_is_run == false) 
		if f_key ~= nil then f_key:close() end
		f_SetValueToFile(s_path_file_contr_beg,"cont")
		b_isNewInf = false
	end
	
	--переменные управления логикой программы
	local b_isFirstKeyOn = true
	local b_isSecondKeyOn = false
	local b_isThirdKeyOn = false
	local b_isFourthKeyOn = false
	--переменные функции
	local n_H_Control 
	local n_L_Control 
	local n_V_Control 
	local n_T_Control = 0
	local n_Time_Prelast_Candle = 0
	local t_o = {}
	local s_str_par = ""
	local s_set_cell2 = ""
	local s_set_cell3 = ""
	local s_set_cell4 = ""
	local s_set_cell5 = ""
	local s_set_cell6 = ""
	--тело программы
	f_FreshBaseData(s_path_file_param)		--обновили данные из файла с исходными параметрами робота
	f_ordering_candles() 					--заказали свечи М1	
	local n_ContrEndDay = 0
	local n_time_candle_sec = n_timeframe * 60
	f_table_creator()						--создаем таблицу
	while b_is_run do
		local b_t,b_b0,b_e0,b_b1,b_e1,b_b2,b_e2 = f_All_in_epoch(s_classcode)
		local cur_time = os.time()
		---[[       					--если торгов нет, то не торгуем
		local n_SleepControl			--блок пропускает, если идет торговая сессия и нет разрыва соединения
		repeat
			n_SleepControl = 0
			while ((cur_time < b_b0 and cur_time >= b_e0)
				or (cur_time > b_b1 and cur_time <= b_e1)
				or (cur_time > b_b2 and cur_time <= b_e2) 
				and b_is_run) do
				sleep(500)
				b_t,b_b0,b_e0,b_b1,b_e1,b_b2,b_e2 = f_All_in_epoch(s_classcode)
				---[[
				do												--блок поиска свечи при паузе в торговле
					if (t_ds ~= nil) and 
						((cur_time > b_b1 and cur_time < b_e1) or
						(cur_time > b_b2 and cur_time < b_e2)) then
						local n_H_Control1, n_L_Control1, n_V_Control1, n_T_Control1 = f_FindSpecCandle()
						if n_H_Control1 ~= 0 and (
							n_H_Control ~= n_H_Control1 or 
							n_L_Control ~= n_L_Control1 or
							n_V_Control ~= n_V_Control1 or
							n_T_Control ~= n_T_Control1) then 							
							n_H_Control = n_H_Control1 
							n_L_Control = n_L_Control1
							n_V_Control = n_V_Control1
							n_T_Control = n_T_Control1 	
							str = "\nОбъем контрольной свечи: "..tostring(n_V_Control)..
										"\nH: "..tostring(n_H_Control)..
										"\nL: "..tostring(n_L_Control)..
										"\nСпред: "..tostring(n_H_Control - n_L_Control)
							message (str)
							f_WLOG(str.." point 1") 
						end
						PrintDbgStr("point 02 В блоке поиска свечи при паузе в торговле") 
					end
				end
				--]]
				cur_time = os.time()
				n_SleepControl = 1
			end
			if b_is_run == false then goto finmain end
			if f_IsDelayExist() then --контролируем падение интернета
				message("Был разрыв соединения") 
				f_WLOG("Был разрыв соединения\n")
				n_SleepControl = 2
			end
		---[[	
		if b_is_run == false then goto finmain end
		until n_SleepControl ==0
		b_isQuoteComeIn = false		--контролируем приход каких либо котировок в QUIK
		repeat
			f_SetTimeInCell()
			---[[
			do												--блок поиска свечи при отсутствии котировок
				cur_time = os.time()
				if (t_ds ~= nil) and 
					((cur_time > b_b1 and cur_time < b_e1) or
					(cur_time > b_b2 and cur_time < b_e2)) then
					local n_H_Control1, n_L_Control1, n_V_Control1, n_T_Control1 = f_FindSpecCandle()
					if n_H_Control1 ~= 0 and (
						n_H_Control ~= n_H_Control1 or 
						n_L_Control ~= n_L_Control1 or
						n_V_Control ~= n_V_Control1 or
						n_T_Control ~= n_T_Control1) then 							
							n_H_Control = n_H_Control1 
							n_L_Control = n_L_Control1
							n_V_Control = n_V_Control1
							n_T_Control = n_T_Control1 	
							str = "\nОбъем контрольной свечи: "..tostring(n_V_Control)..
										"\nH: "..tostring(n_H_Control)..
										"\nL: "..tostring(n_L_Control)..
										"\nСпред: "..tostring(n_H_Control - n_L_Control)
							message (str)
							f_WLOG(str.." point 2")
					end
				end
			end
			--]]
			sleep(40) 
			if b_is_run == false then goto finmain end
		until b_isQuoteComeIn 
		PrintDbgStr("point 03 Блок контроля прихода котировок из вне пройден") 
		if t_ds == nil or t_ds:Size()==0 then		--если оторвались от свечей, переподписываемся еще раз
			f_WLOG("point 04 Оторвались от свечей, переподписываемся")
			PrintDbgStr("point 04 Оторвались от свечей, переподписываемся") 
			f_ordering_candles()
		end
		--считываем данные из файла
		if (b_isNewInf) then 
			local prom_S = f_GetValueFromFile(s_path_file_cur_par)
			local t = f_split_string(prom_S)	
			if t == nil or #t ~= 6 then
				local str = "Какая то хрень с файлом текущих параметров.\nРобот остановлен."
				message(str)
				f_WLOG(str)
				stop_skript()
			end
			--n_ContrEndDay = tonumber(t[1])
			if t[2] == "true" then
				b_isFirstKeyOn = true
			else
				b_isFirstKeyOn = false
			end
			if t[3] == "true" then
				b_isSecondKeyOn = true
			else
				b_isSecondKeyOn = false
			end
			n_OpenPozCur = tonumber(t[4])
			if t[5] ~= "nil" then n_H_Control = tonumber(t[5]) end
			if t[6] ~= "nil" then n_L_Control = tonumber(t[6]) end
			b_isNewInf = false
		end
		do									--выводим информацию в таблицу
			f_SetTimeInCell()
			if s_demomode ~= "YES" and s_demomode ~= "NO" then
				local str = "Не смог воспроизвести параметр s_demomode. \ns_demomode = "..tostring(s_demomode).."\nСкрипт остановлен."
				f_WLOG(str)
				message(str)
				stop_skript()
			end
			if s_demomode == "YES" then
				if s_set_cell2 ~= "Демо" then
					SetCell(tt, 1, 2, "Демо")
					s_set_cell2 = "Демо"
				end	
			else	
				if s_set_cell2 ~= "Боевой" then
					SetCell(tt, 1, 2, "Боевой")
					s_set_cell2 = "Боевой"
				end
			end
			local n_n = t_ds:Size()			
			local n_cur_price = t_ds:C(n_n)
			if s_set_cell3 ~= tostring(n_cur_price) then
				SetCell(tt, 1, 3, tostring(n_cur_price))
				s_set_cell3 = tostring(n_cur_price)
			end
			if s_set_cell4 ~= tostring(n_H_Control) then
				SetCell(tt, 1, 4, tostring(n_H_Control))
				s_set_cell4 = tostring(n_H_Control)
			end
			if s_set_cell5 ~= tostring(n_L_Control) then
				SetCell(tt, 1, 5, tostring(n_L_Control))
				s_set_cell5 = tostring(n_L_Control)
			end
			if n_OpenPozCur == 1 then 
				if s_set_cell6 ~= tostring(n_L_Control) then
				SetCell(tt, 1, 6, tostring(n_L_Control))
				s_set_cell6 = tostring(n_L_Control)
			end
			elseif 	n_OpenPozCur == -1 then
				if s_set_cell6 ~= tostring(n_H_Control) then
					SetCell(tt, 1, 6, tostring(n_H_Control))
					s_set_cell6 = tostring(n_H_Control)
				end
			else
				if s_set_cell6 ~= tostring("-----") then
					SetCell(tt, 1, 6, tostring("-----"))
					s_set_cell6 = tostring("-----")
				end
		end
				
		end
		local datetime = os.date("!*t",os.time())
		local nsw = t_ds:Size()
		local CT = t_ds:T(nsw)
		if (n_ContrEndDay < os.time()) 				-- один раз в день, как только появились данные о свече в сгодняшнем дне, 
			and (datetime.year == CT.year)			--создаем лист времени свечей за сегодняшний и предыдущий торговый день в epo формате
			and (datetime.month == CT.month)
			and (datetime.day == CT.day) then 	
				f_ListCandlesCreator(n_time_candle_sec)
				n_ContrEndDay = b_e0 + (5 * 60 * 60)		--сдвигаем на 5 часов от конца торгового периода, что бы повторное создание листа времени не началось раньше утра следующего дня
 		end
		if b_isFirstKeyOn then			--ищем свечу для входа, рассматриваем полностью сформированную предпоследнюю свечу
			n_H_Control, n_L_Control, n_V_Control, n_T_Control = f_FindSpecCandle()
			if n_H_Control ~= 0 then	--нашли такую свечу
				str = "\nОбъем контрольной свечи: "..tostring(n_V_Control)..
					"\nH: "..tostring(n_H_Control)..
					"\nL: "..tostring(n_L_Control)..
				"\nСпред: "..tostring(n_H_Control - n_L_Control)
				message (str)
				f_WLOG(str.." point 3")
				b_isFirstKeyOn = false
				b_isSecondKeyOn = true 	--передали управление блоку по отслеживанию пробоя границ свечи
			end
		end
		if b_isSecondKeyOn then			--ищем новую свечу или пробой границ 	
			--stop_script()
			if os.time() > (n_T_Control + n_timeframe * 60 *2 - 1) then 		--появилась новая свеча, проверяем на новую свечу входа
				local n_H_Control1, _,_,_ = f_FindSpecCandle()
				if n_H_Control1 ~= 0 then 								--удовлетворяет условиям
					b_isFirstKeyOn = true
					b_isSecondKeyOn = false 							--передали управление блоку по отслеживанию записи данных по новой свече 
				end
			end
			if b_isSecondKeyOn then										--менять данные по свече не надо. Проверяем на пробой в две стороны
				local n_n = t_ds:Size()			
				local n_cur_price = t_ds:C(n_n)							--последняя цена
				if (n_cur_price > n_H_Control) then						--пробой вверх верхней границы
					if s_typesize == "LONG" then								--включен режим лонг
						if n_OpenPozCur > 0 then								--открыта позиция в лонг
							--ниего не делается
						elseif n_OpenPozCur == 0 then							--нет открытой позиции
							t_o.side = "B"
							t_o.price = n_H_Control
							t_o.ratio = 1
							f_done_order(t_o)										--открываем позицию в лонг
							n_OpenPozCur = 1										--записали, что открыли позицию в лонг
						end
					end
					if s_typesize == "REVERS" then								--включен режим реверс
						if n_OpenPozCur > 0 then								--открыта позиция в лонг
							--ниего не делается
						elseif n_OpenPozCur == 0 then							--нет открытой позиции
							t_o.side = "B"
							t_o.price = n_H_Control
							t_o.ratio = 1
							f_done_order(t_o)										--открываем позицию в лонг
							n_OpenPozCur = 1										--записали, что открыли позицию в лонг
						elseif n_OpenPozCur < 0	then								--открыта позиция шорт
							t_o.side = "B"											--переворачиваем позицию, покупая двойной объем
							t_o.price = n_H_Control
							t_o.ratio = 2
							f_done_order(t_o)										--открываем позицию в лонг
							n_OpenPozCur = 1										--записали, что перевернули позицию в лонг
						end
					end
					if s_typesize == "SHORT" then								--включен режим шорт
						if n_OpenPozCur == 0 then								--нет открытой позиции
							--ниего не делается
						elseif n_OpenPozCur < 0 then							--открыт шорт
							t_o.side = "B"
							t_o.price = n_H_Control
							t_o.ratio = 1
							f_done_order(t_o)										--закрываем позицию в 0
							n_OpenPozCur = 0										--записали, что закрыли позицию
						end
					end
				end
				if (n_cur_price < n_L_Control) then								--пробой вниз нижней границы
					if s_typesize == "LONG" then										--включен режим лонг
						if n_OpenPozCur > 0 then										--открыта позиция в лонг
							t_o.side = "S"
							t_o.price = n_L_Control
							t_o.ratio = 1
							f_done_order(t_o)											--закрываем позицию в 0
							n_OpenPozCur = 0											--записали, что закрыли позицию
						elseif n_OpenPozCur == 0 then								--нет открытой позиции
							--ничего не делаем
						end
					elseif s_typesize == "REVERS" then
						if n_OpenPozCur < 0 then									--открыта позиция в шорт
							--ниего не делается
						elseif n_OpenPozCur == 0 then							--нет открытой позиции
							t_o.side = "S"
							t_o.price = n_L_Control
							t_o.ratio = 1
							f_done_order(t_o)										--открываем позицию в шорт
							n_OpenPozCur = -1										--записали, что открыли позицию в шорт
						elseif n_OpenPozCur > 0	then							--открыта позиция лонг
							t_o.side = "S"											--переворачиваем позицию, покупая двойной объем
							t_o.price = n_L_Control
							t_o.ratio = 2
							f_done_order(t_o)									--открываем позицию в шорт
							n_OpenPozCur = -1									--записали, что перевернули позицию в шорт
						end
					elseif s_typesize == "SHORT" then
						if n_OpenPozCur < 0 then								--открыта позиция шорт
							--ничего не делаем
						elseif n_OpenPozCur == 0 then								--нет открытой позиции
							t_o.side = "S"
							t_o.price = n_L_Control
							t_o.ratio = 1
							f_done_order(t_o)											--открываем позицию в 0
							n_OpenPozCur = -1											--записали, что открыли короткую позицию
						end
					end
				end
			end
		end
		local str1 = tostring(n_ContrEndDay).." "..tostring(b_isFirstKeyOn).." "..tostring(b_isSecondKeyOn).." "..tostring(n_OpenPozCur)
					.." "..tostring(n_H_Control).." "..tostring(n_L_Control)
		if str1 ~= s_str_par then													--если информация не изменилась, не записываем
			f_SetValueToFile(s_path_file_cur_par,str1)
			f_WLOG(str1)
			s_str_par = str1
			b_isNewInf = true
		end	
		sleep(10)
	end
	::finmain::
	t_ds:Close()
	DestroyTable(tt)
end

function f_done_order(t_t)
	if s_demomode == 'YES' then
		local direct
		if t_t.side == "B" then
			direct = "Купля"
		else
			direct = "Продажа"
		end
		local str = "Выставляем заявку в бумаге: "..s_seccode..
				".\nНаправление: "..direct..
				"\nЦена заявки: "..tostring(t_t.price)..
				".\nКоличество лотов: "..tostring(n_amnt*t_t.ratio)
				message(str)
			f_WLOG(str)	
		return
	end
	if s_ordertype == 'MARKET' then
		f_done_in_market(t_t)
		return
	elseif s_ordertype == 'LIMIT' then		--выставляем лимитный ордер
		f_send_limit_order(t_t)	
		local n_n = t_ds:Size()
		local n_Time_Last_Candle = os.time(t_ds:T(n_n))
		repeat
			sleep(50)
			local n_n1 = t_ds:Size()
			local n_Time_Last_Candle_Next = os.time(t_ds:T(n_n1))
		until n_Time_Last_Candle_Next > n_Time_Last_Candle
		if t_OrderNew.balance > 0 then						--остались неисполненные лоты от заявки
			local n_ost = t_OrderNew.balance		--осталось неисполненных лотов
			f_killLimitFO(s_classcode,s_seccode,t_OrderNew.order_num)
			f_done_in_market(t_t,n_ost,1)
			return
		end
	else
		local str = "Критическая ошибка в указании типа ордера.\nСкрипт остановлен."
		message(str)
		f_WLOG(str)
		stop_script()
	end
end

function f_killLimitFO(class,security,num_or)	--снятие лимитированной заявки
	--     1. ID присвоенной транзакции либо nil если транзакция отвергнута на уровне сервера Квик 
	--     2. Ответное сообщение сервера Квик либо строку с параметрами транзакции
	if (class==nil or security==nil or num_or==nil) then
		return nil,"SendLimitFO: Can`t send order. Nil parameters."
	end
	LastStatus = nil
	trans_id=math.random(1,2147483647)  
	local transaction={
		["TRANS_ID"]=tostring(trans_id),
		["ACTION"]="KILL_ORDER",
		["CLASSCODE"]=class,
		["SECCODE"]=security,
		["ORDER_KEY"]=tostring(num_or)
	}
	local res=sendTransaction(transaction)
	if res~="" then
		return nil, "killLimitFO:"..res
	else
		return trans_id, "killLimitFO(): Limit order number "..tostring(num_or).." killed successfully."
	end
end

function f_TransSender(SEC_CODE,OP_ERATION,QUAN_TITY,PRI_CE) 				-- Отправляет транзакцию на открытие позиции
	-- Выставляет заявку на открытие позиции
	-- Получает ID для следующей транзакции
	n_trans_id = n_trans_id + 1
	s_QUAN_TITY = string.format("%i",QUAN_TITY)
	local Transaction={
		['TRANS_ID']  = tostring(n_trans_id),   	-- Номер транзакции
		['ACCOUNT']   = s_account ,              	-- Код счета
		['CLASSCODE'] = s_classcode,           		-- Код класса
		['SECCODE']   = SEC_CODE,             		-- Код инструмента
		['ACTION']    = 'NEW_ORDER',          		-- Тип транзакции ('NEW_ORDER' - новая заявка)
		['OPERATION'] = OP_ERATION,           		-- Операция ('B' - buy, или 'S' - sell)
		['TYPE']      = 'L',                  		-- Тип ('L' - лимитированная, 'M' - рыночная)
		['QUANTITY']  = s_QUAN_TITY,		  		-- Количество в лотах
		['PRICE']     = tostring(PRI_CE)  	  		-- Цена
	}
  -- Отправляет транзакцию
  local Res = sendTransaction(Transaction)
  if Res ~= '' then 
	local str = 'TransSender(): Критическая ошибка отправки транзакции: '..Res.."\nСкрипт остановлен.\n"
	message(str) 
	f_WLOG(str)
	stop_script()
else 
	local str = 'TransSender(): Транзакция отправлена'
	f_WLOG(str)
end
end

function f_done_in_market(t_t,n_l_amnt,n_sp_ratio) --выставление ордера по рынку
	n_l_amnt = n_l_amnt or n_amnt
	n_sp_ratio = n_sp_ratio or t_t.ratio
	local n_lPrice = 0.0
	local t_rezult = getParamEx(s_classcode, s_seccode, "last") --вытаскиваем цену последней сделки в виде таблицы
	if t_t.side == 'S' then
		n_lPrice = tonumber(t_rezult.param_value) * 0.99    
		if n_lPrice < tonumber(getParamEx(s_classcode, s_seccode, "low").param_value) then 
			s_lPrice =  getParamEx(s_classcode, s_seccode, "low").param_value 
		else
			s_lPrice = tostring(n_lPrice)  									
		end
	else
		n_lPrice = tonumber(t_rezult.param_value) * 1.01    
		if n_lPrice > tonumber(getParamEx(s_classcode, s_seccode, "high").param_value) then 
			s_lPrice =  getParamEx(s_classcode, s_seccode, "high").param_value 
		else
			s_lPrice = tostring(n_lPrice)  									
		end
	end
	s_lPrice = toPrice(s_seccode, s_lPrice, s_classcode) -- вернули стринг правильного формата
	n_LastStatus = nil
	t_OrderNew = nil
	if t_t.side == 'S' then
		f_TransSender(s_seccode,"S", n_l_amnt * n_sp_ratio,s_lPrice)
	else
		f_TransSender(s_seccode,"B", n_l_amnt * n_sp_ratio,s_lPrice)
	end
	local n_account = 0   --счетчик количества циклов при ожидании, что заявка прошла
	repeat
		sleep(10)
		n_account = n_account + 1
	until n_LastStatus == 3 or n_account > 1000
	if n_account > 1000 then  --счетчик циклов переполнен, останавливаем скрипт.
		local str = "Критическая ошибка с выставлением транзакции.\nСкрипт остановлен.\n"
		message(str)
		f_WLOG(str)
		stop_script()
	end
	n_account = 0   --счетчик количества циклов при ожидании, что заявка отобразилась в таблице заявок
	repeat
		sleep(10)
		n_account = n_account + 1
	until t_OrderNew ~= nil or n_account > 1000
	if n_account > 1000 then  --счетчик циклов переполнен, останавливаем скрипт.
		local str = "Критическая ошибка при ожидании подтверждения исполнения заявки.\nСкрипт остановлен.\n"
		message(str)
		f_WLOG(str)
		stop_script()
	end
	return
end

function f_send_limit_order(t_t)
	n_LastStatus = nil
	t_OrderNew = nil
	s_lPrice = tostring(t_t.price)
	if t_t.side == 'S' then
		f_TransSender(s_seccode,"S", n_amnt*t_t.ratio,s_lPrice)
	else
		f_TransSender(s_seccode,"B", n_amnt*t_t.ratio,s_lPrice)
	end
	local n_account = 0   --счетчик количества циклов при ожидании, что заявка прошла
	repeat
		sleep(10)
		n_account = n_account + 1
	until n_LastStatus == 3 or n_account > 1000
	if n_account > 1000 then  --счетчик циклов переполнен, останавливаем скрипт.
		local str = "Критическая ошибка с выставлением транзакции.\nСкрипт остановлен.\n"
		message(str)
		f_WLOG(str)
		stop_script()
	end
	n_account = 0   --счетчик количества циклов при ожидании, что заявка отобразилась в таблице заявок
	repeat
		sleep(10)
		n_account = n_account + 1
	until t_OrderNew ~= nil or n_account > 1000
	if n_account > 1000 then  --счетчик циклов переполнен, останавливаем скрипт.
		local str = "Критическая ошибка при ожидании подтверждения исполнения заявки.\nСкрипт остановлен.\n"
		message(str)
		f_WLOG(str)
		stop_script()
	end
	return
end

function f_FindSpecCandle()		--функция нахождения необходимой свечи с заданными параметрами. Возвращает два числа: максимум и минимум свечи, или 0, 0.
	local H,L,V, T0 = f_PrelastCandleFinder()
	local datetime1 = os.date("!*t",T0)
	PrintDbgStr("point 01: H - L = "..tostring(H-L).."; V = "..tostring(V).."; время начала свечи: "..os.date("%X",os.time(datetime1)+offset))  
	if V >= n_controlvalue and (H-L) >= n_deltacandle then --нашли свечу
		return H,L,V,T0
	end
	return 0,0,0,0
end

function f_GetValueFromFile(FileName) -- Читаем данные из файла.
	local f = io.open(FileName, "r");
	if f ~= nil then
		s_Value = f:read("*all")
		f:close()
		return s_Value
	end
	return ""
end

function f_SetValueToFile(FileName, s_Value) -- Пишем параметр в файл.
	local ff=io.open(FileName, "w") -- используем "w", а не "a", чтобы перезаписать существующий.
	ff:write(s_Value)
	ff:close()
end

function OnStop(stop_flag)
	b_is_run=false
	DestroyTable(tt)
	sleep(1000)
end

function f_WLOG(st) -- Универсальная функция записи в лог.
	local l_file=io.open(s_path_to_file..s_log_file_name, "a") -- используем "a", чтобы добавить новую строку.
	l_file:write(os.date().." "..st.."\n")
	l_file:close()
end
