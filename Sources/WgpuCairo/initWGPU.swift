import Foundation
import SDL2
import SwiftWgpuTools

class AdapterRequestData {
    var adapter: UnsafeMutablePointer<WGPUAdapter?>
    var semaphore: DispatchSemaphore

    init(adapter: UnsafeMutablePointer<WGPUAdapter?>, semaphore: DispatchSemaphore) {
        self.adapter = adapter
        self.semaphore = semaphore
    }
}

class DeviceRequestData {
    var device: UnsafeMutablePointer<WGPUDevice?>
    var semaphore: DispatchSemaphore

    init(device: UnsafeMutablePointer<WGPUDevice?>, semaphore: DispatchSemaphore) {
        self.device = device
        self.semaphore = semaphore
    }
}

func initWGPU(window: OpaquePointer) -> (surface: WGPUSurface, device: WGPUDevice, queue: WGPUQueue, config: WGPUSurfaceConfiguration) {

    // Get window size & scaleFactor
    var drawableSize = (width: Int32(0), height: Int32(0))
    SDL_GL_GetDrawableSize(window, &drawableSize.width, &drawableSize.height)
    drawableSize.width = max(drawableSize.width, 1)
    drawableSize.height = max(drawableSize.height, 1)

    var logicalSize = (width: Int32(0), height: Int32(0))
    SDL_GetWindowSize(window, &logicalSize.width, &logicalSize.height)
    logicalSize.width = max(logicalSize.width, 1)
    logicalSize.height = max(logicalSize.height, 1)

    let scaleFactor = Double(drawableSize.width) / Double(logicalSize.width)

    // Crear WGPU instance
    var extras = WGPUInstanceExtras(
        chain: WGPUChainedStruct(next: nil, sType: BACKEND_CHAIN),
        backends: WGPUInstanceBackendFlags(BACKEND_FLAGS),
        flags: 0,
        dx12ShaderCompiler: WGPUDx12Compiler_Dxc,
        gles3MinorVersion: WGPUGles3MinorVersion_Automatic,
        dxilPath: nil,
        dxcPath: nil
    )

    var descriptor = withUnsafePointer(to: &extras.chain) { chainPointer in WGPUInstanceDescriptor(nextInChain: chainPointer) }
    guard let instance = withUnsafePointer(to: &descriptor, { wgpuCreateInstance($0) }) else {
        fatalError("Could not initialize WGPU instance")
    }
    
    // List adapters
    print("Available adapters:")
    
    let backendFlags: WGPUInstanceBackendFlags = WGPUInstanceBackendFlags(BACKEND_FLAGS)
    var enumerateOptions = WGPUInstanceEnumerateAdapterOptions(nextInChain: nil, backends: backendFlags)
    let adapterCount = wgpuInstanceEnumerateAdapters(instance, &enumerateOptions, nil)
    var adapters: [WGPUAdapter?] = Array(repeating: nil, count: Int(adapterCount))
    let bufferPointer = adapters.withUnsafeMutableBufferPointer { $0 }
    wgpuInstanceEnumerateAdapters(instance, &enumerateOptions, bufferPointer.baseAddress)

    for adapter in adapters {
        if let adapter = adapter {
            var properties = WGPUAdapterProperties()
            wgpuAdapterGetProperties(adapter, &properties)
            print("   \(String(cString: properties.name))")
        }
    }

    // Get a surface
    guard let surface = getWGPUSurface(instance: instance, window: window) else {
        fatalError("Failed to create WGPU surface")
    }

    // Get an adapter
    var adapter: WGPUAdapter? = nil
    var options = WGPURequestAdapterOptions(
        nextInChain: nil,
        compatibleSurface: surface,
        powerPreference: WGPUPowerPreference_HighPerformance,
        backendType: WGPUBackendType_Undefined,
        forceFallbackAdapter: WGPUBool(0)
    )
    
    let adapterSemaphore = DispatchSemaphore(value: 0)
    
    // Crear un contenidor per a passar l'adapter i el semàfor
    let userData = AdapterRequestData(adapter: &adapter, semaphore: adapterSemaphore)
    let userDataPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(userData).toOpaque())
    
    wgpuInstanceRequestAdapter(instance, &options, requestAdapterCallback, userDataPointer)
    
    print("Waiting Adapter Semaphore")
    adapterSemaphore.wait()
    print("Adapter Semaphore received")

    guard let adapter = adapter else {
        fatalError("Failed to get WGPU adapter")
    }

    // Request a device and queue from the adapter
    var deviceDescriptor = WGPUDeviceDescriptor(
        nextInChain: nil, 
        label: nil, 
        requiredFeatureCount: 0, 
        requiredFeatures: nil, 
        requiredLimits: nil,     
        defaultQueue: WGPUQueueDescriptor(nextInChain: nil, label: nil),
        deviceLostCallback: nil, 
        deviceLostUserdata: nil  
    )

    var device: WGPUDevice? = nil
    let deviceSemaphore = DispatchSemaphore(value: 0)
    
    let deviceUserData = DeviceRequestData(device: &device, semaphore: deviceSemaphore)
    let deviceUserDataPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(deviceUserData).toOpaque())
    
    wgpuAdapterRequestDevice(adapter, &deviceDescriptor, requestDeviceCallback, deviceUserDataPointer)
    
    print("Waiting Device Semaphore")
    deviceSemaphore.wait()
    print("Device Semaphore received")
    
    // Get the device and queue
    guard let device = device else {
        fatalError("Failed to create WGPU device")
    }
    guard let queue = wgpuDeviceGetQueue(device) else {
        fatalError("Failed to get WGPU queue")
    }

    // Configure the surface
    var surfaceConfig = WGPUSurfaceConfiguration(
        nextInChain: nil,
        device: device,
        format: WGPUTextureFormat_BGRA8Unorm, // The format used in the original code
        usage: WGPUTextureUsage_RenderAttachment.rawValue,
        viewFormatCount: 0, // Set to 0 if you're not using additional view formats
        viewFormats: nil,   // Set to nil if no additional view formats are used
        alphaMode: WGPUCompositeAlphaMode_Auto, // Default alpha mode
        width: UInt32(Double(logicalSize.width) * scaleFactor),
        height: UInt32(Double(logicalSize.height) * scaleFactor),
        presentMode: WGPUPresentMode_Fifo // The present mode used in the original code
    )
    wgpuSurfaceConfigure(surface, &surfaceConfig)
    
    return (surface, device, queue, surfaceConfig)
}

func requestAdapterCallback(status: WGPURequestAdapterStatus, requestedAdapter: WGPUAdapter?, message: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    print("Adapter callback executed with status: \(status.rawValue)")
    
    if let userData = userData {
        let adapterRequestData = Unmanaged<AdapterRequestData>.fromOpaque(userData).takeUnretainedValue()

        if status == WGPURequestAdapterStatus_Success, let adapter = requestedAdapter {
            adapterRequestData.adapter.pointee = adapter
            var properties = WGPUAdapterProperties()
            wgpuAdapterGetProperties(adapter, &properties)
            print("Selected adapter:")
            print("   Adapter Name: \(String(cString: properties.name))")
            print("   Vendor ID: \(properties.vendorID)")
            print("   Device ID: \(properties.deviceID)")
            print("   Backend Type: \(properties.backendType.rawValue)")
        } else {
            let errorMessage = message != nil ? String(cString: message!) : "Unknown error"
            print("Adapter request failed: \(errorMessage)")
        }

        print("Adapter Semaphore before signal")
        adapterRequestData.semaphore.signal()
        print("Adapter Semaphore after signal")
    } else {
        print("Error: userData is nil")
    }
}

func requestDeviceCallback(status: WGPURequestDeviceStatus, requestedDevice: WGPUDevice?, message: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    print("Device callback executed with status: \(status.rawValue)")

    if let userData = userData {
        let deviceRequestData = Unmanaged<DeviceRequestData>.fromOpaque(userData).takeUnretainedValue()

        if status == WGPURequestDeviceStatus_Success, let device = requestedDevice {
            deviceRequestData.device.pointee = device
            print("WGPU device successfully created.")
        } else {
            let errorMessage = message != nil ? String(cString: message!) : "Unknown error"
            print("Device request failed: \(errorMessage)")
        }

        print("Device Semaphore before signal")
        deviceRequestData.semaphore.signal()
        print("Device Semaphore after signal")
    } else {
        print("Error: userData is nil")
    }
}
