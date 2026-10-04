return [[local Invocations = 0

local SendSize = 64
local SendOffset = 0
local SendCursor = 0
local SendBuffer = buffer.create(64)
local SendInstances = {}

local RecieveCursor = 0
local RecieveBuffer = buffer.create(64)

local RecieveInstances = {}
local RecieveInstanceCursor = 0

local Null = newproxy()

type Entry = {
    value: any,
    next: Entry?
}

type Queue = {
    head: Entry?,
    tail: Entry?
}

type BufferSave = {
    Size: number, 
    Cursor: number, 
    Buffer: buffer, 
    Instances: {Instance}
}

local function Read(Bytes: number)
    local Offset = RecieveCursor
    RecieveCursor += Bytes
    return Offset
end

local function Save(): BufferSave
    return {
        Size = SendSize,
        Cursor = SendCursor,
        Buffer = SendBuffer,
        Instances = SendInstances
    }
end

local function Load(Save: BufferSave?)
    if Save then
        SendSize = Save.Size
        SendCursor = Save.Cursor
        SendOffset = Save.Cursor
        SendBuffer = Save.Buffer
        SendInstances = Save.Instances
        return
    end

    SendSize = 64
    SendCursor = 0
    SendOffset = 0
    SendBuffer = buffer.create(64)
    SendInstances = {}
end

local function Invoke()
    if Invocations == 255 then
        Invocations = 0
    end

    local Invocation = Invocations
    Invocations += 1
    return Invocation
end

local function Allocate(Bytes: number)
    local InUse = (SendCursor + Bytes)
    if InUse > SendSize then
        --> Avoid resizing the buffer for every write
        while InUse > SendSize do
            SendSize *= 1.5
        end

        local Buffer = buffer.create(SendSize)
        buffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)
        SendBuffer = Buffer
    end

    SendOffset = SendCursor
    SendCursor += Bytes
    
    return SendOffset
end

-- Runs a generated serializer as a transaction. A serializer that throws
-- part-way through would otherwise leave its header byte and any references it
-- appended behind in the batch, so every later event in that batch decodes
-- against a corrupted cursor. Only the cursors are restored: if the buffer grew
-- during the failed write the larger buffer is kept, which stays consistent.
local function Serialize(WriteFunction: (...any) -> (), ...: any)
    local Cursor = SendCursor
    local Instances = #SendInstances

    local Success, Message = pcall(WriteFunction, ...)

    if not Success then
        SendCursor = Cursor
        SendOffset = Cursor
        while #SendInstances > Instances do
            table.remove(SendInstances)
        end

        error(Message, 0)
    end
end

-- Export helpers. These are user-invoked rather than on the per-event hot path,
-- so they may allocate a results table in exchange for restoring borrowed state
-- on every exit path. Without this, an export that throws part-way through
-- leaves the receive cursor pointing into the export's own buffer, which breaks
-- every remaining event in the batch it was called from.
local function ExportRead(ReadFunction: (...any) -> ...any, ...: any): ...any
    local Cursor, Buffer, InstanceCursor = RecieveCursor, RecieveBuffer, RecieveInstanceCursor
    local Results = table.pack(pcall(ReadFunction, ...))

    if not Results[1] then
        RecieveCursor, RecieveBuffer, RecieveInstanceCursor = Cursor, Buffer, InstanceCursor
        error(Results[2], 0)
    end

    return table.unpack(Results, 2, Results.n)
end

local function ExportWrite(WriteFunction: (...any) -> ...any, ...: any): ...any
    local Previous = Save()
    local Results = table.pack(pcall(WriteFunction, ...))
    Load(Previous)

    if not Results[1] then
        error(Results[2], 0)
    end

    return table.unpack(Results, 2, Results.n)
end

local function CreateQueue(): Queue
    return {
        head = nil,
        tail = nil
    }
end

local function Pop(queue: Queue): any
    local head = queue.head
    if head == nil then
        return
    end

    queue.head = head.next
    return head.value
end

local function Push(queue: Queue, value: any)
    local entry: Entry = {
        value = value,
        next = nil
    }

    if queue.tail ~= nil then
        queue.tail.next = entry
    end

    queue.tail = entry

    if queue.head == nil then
        queue.head = entry
    end
end

local Calls = table.create(256)

local Events: any = {
    Reliable = table.create(256),
    Unreliable = table.create(256)
}

local Queue: any = {
    Reliable = table.create(256),
    Unreliable = table.create(256)
}

]]
