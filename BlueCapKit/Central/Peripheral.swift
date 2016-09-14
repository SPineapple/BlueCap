//
//  Peripheral.swift
//  BlueCap
//
//  Created by Troy Stribling on 6/8/14.
//  Copyright (c) 2014 Troy Stribling. The MIT License (MIT).
//

import Foundation
import CoreBluetooth

// MARK - Connection Error -
enum PeripheralConnectionError {
    case none, timeout
}

public enum ConnectionEvent {
    case connect, timeout, disconnect, forceDisconnect, giveUp
}

// MARK: - PeripheralAdvertisements -

public struct PeripheralAdvertisements {
    
    let advertisements: [String : Any]
    
    public var localName: String? {
        return self.advertisements[CBAdvertisementDataLocalNameKey] as? String
    }
    
    public var manufactuereData: Data? {
        return self.advertisements[CBAdvertisementDataManufacturerDataKey] as? Data
    }
    
    public var txPower: NSNumber? {
        return self.advertisements[CBAdvertisementDataTxPowerLevelKey] as? NSNumber
    }
    
    public var isConnectable: NSNumber? {
        return self.advertisements[CBAdvertisementDataIsConnectable] as? NSNumber
    }
    
    public var serviceUUIDs: [CBUUID]? {
        return self.advertisements[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
    }
    
    public var serviceData: [CBUUID:Data]? {
        return self.advertisements[CBAdvertisementDataServiceDataKey] as? [CBUUID:Data]
    }
    
    public var overflowServiceUUIDs: [CBUUID]? {
        return self.advertisements[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]
    }
    
    public var solicitedServiceUUIDs: [CBUUID]? {
        return self.advertisements[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID]
    }    
}

// MARK: - Peripheral -

public class Peripheral: NSObject, CBPeripheralDelegate {

    // MARK: Serialize Property IO

    static let ioQueue = Queue("us.gnos.blueCap.peripheral")

    fileprivate var servicesDiscoveredPromise: Promise<Peripheral>?
    fileprivate var readRSSIPromise: Promise<Int>?
    fileprivate var pollRSSIPromise: StreamPromise<Int>?
    fileprivate var connectionPromise: StreamPromise<(peripheral: Peripheral, connectionEvent: ConnectionEvent)>?

    fileprivate let profileManager: ProfileManager?

    fileprivate var _RSSI: Int = 0
    fileprivate var _state = CBPeripheralState.disconnected

    fileprivate var _timeoutCount: UInt = 0
    fileprivate var _disconnectionCount: UInt = 0

    fileprivate var connectionSequence = 0
    fileprivate var RSSISequence = 0
    fileprivate var serviceDiscoverySequence = 0
    fileprivate var forcedDisconnect = false

    fileprivate var _currentError = PeripheralConnectionError.none

    fileprivate var _connectedAt: Date?
    fileprivate var _disconnectedAt : Date?
    fileprivate var _totalSecondsConnected = 0.0

    fileprivate var connectionTimeout = Double.infinity
    fileprivate var timeoutRetries = UInt.max
    fileprivate var disconnectRetries = UInt.max

    fileprivate(set) weak var centralManager: CentralManager?

    let centralQueue: Queue
    var discoveredServices = SerialIODictionary<CBUUID, Service>(Peripheral.ioQueue)
    var discoveredCharacteristics = SerialIODictionary<CBUUID, Characteristic>(Peripheral.ioQueue)

    internal fileprivate(set) var cbPeripheral: CBPeripheralInjectable
    public let advertisements: PeripheralAdvertisements
    public let discoveredAt = Date()

    // MARK: Serial Properties

    fileprivate var currentError: PeripheralConnectionError {
        get {
            return Peripheral.ioQueue.sync { return self._currentError }
        }
        set {
            Peripheral.ioQueue.sync { self._currentError = newValue }
        }
    }

    fileprivate var _secondsConnected: Double {
        if let disconnectedAt = self._disconnectedAt, let connectedAt = self._connectedAt {
            return disconnectedAt.timeIntervalSince(connectedAt)
        } else if let connectedAt = self._connectedAt {
            return Date().timeIntervalSince(connectedAt)
        } else {
            return 0.0
        }
    }

    // MARK: Public Properties

    public var RSSI: Int {
        get {
            return Peripheral.ioQueue.sync { return self._RSSI }
        }
        set {
            Peripheral.ioQueue.sync { self._RSSI = newValue }
        }
    }

    public fileprivate(set) var connectedAt: Date? {
        get {
            return Peripheral.ioQueue.sync { return self._connectedAt }
        }
        set {
            Peripheral.ioQueue.sync { self._connectedAt = newValue }
        }
    }

    public var disconnectedAt: Date? {
        return centralQueue.sync { return self._disconnectedAt }
    }

    public var timeoutCount: UInt {
        return centralQueue.sync  { return self._timeoutCount }
    }

    public var disconnectionCount: UInt {
        return centralQueue.sync { return self._disconnectionCount }
    }

    public var connectionCount: Int {
        return centralQueue.sync { return self.connectionSequence }
    }

    public var secondsConnected: Double {
        return centralQueue.sync { return self._secondsConnected }
    }

    public var totalSecondsConnected: Double {
        return centralQueue.sync { return self._totalSecondsConnected }
    }

    public var cumlativeSecondsConnected: Double {
        return self.disconnectedAt != nil ? self.totalSecondsConnected : self.totalSecondsConnected + self.secondsConnected
    }

    public var cumlativeSecondsDisconnected: Double {
        return Date().timeIntervalSince(self.discoveredAt) - self.cumlativeSecondsConnected
    }

    public var name: String {
        if let name = self.cbPeripheral.name {
            return name
        } else {
            return "Unknown"
        }
    }

    public var services: [Service] {
        return Array(self.discoveredServices.values)
    }
    
    public var identifier: UUID {
        return self.cbPeripheral.identifier as UUID
    }

    public func service(_ uuid: CBUUID) -> Service? {
        return self.discoveredServices[uuid]
    }

    public var state: CBPeripheralState {
        get {
            return cbPeripheral.state
        }
    }

    // MARK: Initializers

    internal init(cbPeripheral: CBPeripheralInjectable, centralManager: CentralManager, advertisements: [String : Any], RSSI: Int, profileManager: ProfileManager? = nil) {
        self.cbPeripheral = cbPeripheral
        self.centralManager = centralManager
        self.advertisements = PeripheralAdvertisements(advertisements: advertisements)
        self.profileManager = profileManager
        self.centralQueue = centralManager.centralQueue
        super.init()
        self.RSSI = RSSI
        self.cbPeripheral.delegate = self
    }

    internal init(cbPeripheral: CBPeripheralInjectable, centralManager: CentralManager, profileManager: ProfileManager? = nil) {
        self.cbPeripheral = cbPeripheral
        self.centralManager = centralManager
        self.advertisements = PeripheralAdvertisements(advertisements: [String : AnyObject]())
        self.profileManager = profileManager
        self.centralQueue = centralManager.centralQueue
        super.init()
        self.RSSI = 0
        self.cbPeripheral.delegate = self
    }

    internal init(cbPeripheral: CBPeripheralInjectable, bcPeripheral: Peripheral, profileManager: ProfileManager? = nil) {
        self.cbPeripheral = cbPeripheral
        self.advertisements = bcPeripheral.advertisements
        self.centralManager = bcPeripheral.centralManager
        self.centralQueue = bcPeripheral.centralManager!.centralQueue
        self.profileManager = profileManager
        super.init()
        self.RSSI = bcPeripheral.RSSI
        self.cbPeripheral.delegate = self
    }

    deinit {
        self.cbPeripheral.delegate = nil
    }

    // MARK: RSSI

    public func readRSSI() -> Future<Int> {
        return centralQueue.sync {
            if let readRSSIPromise = self.readRSSIPromise, !readRSSIPromise.completed {
                return readRSSIPromise.future
            }
            Logger.debug("name = \(self.name), uuid = \(self.identifier.uuidString)")
            self.readRSSIPromise = Promise<Int>()
            self.readRSSIIfConnected()
            return self.readRSSIPromise!.future
        }
    }

    public func startPollingRSSI(_ period: Double = 10.0, capacity: Int = Int.max) -> FutureStream<Int> {
        return centralQueue.sync {
            if let pollRSSIPromise = self.pollRSSIPromise {
                return pollRSSIPromise.stream
            }
            Logger.debug("name = \(self.name), uuid = \(self.identifier.uuidString), period = \(period)")
            self.pollRSSIPromise = StreamPromise<Int>(capacity: capacity)
            self.readRSSIIfConnected()
            self.RSSISequence += 1
            self.pollRSSI(period, sequence: self.RSSISequence)
            return self.pollRSSIPromise!.stream
        }
    }

    public func stopPollingRSSI() {
        centralQueue.sync {
            Logger.debug("name = \(self.name), uuid = \(self.identifier.uuidString)")
            self.pollRSSIPromise = nil
        }
    }

    // MARK: Connection

    public func reconnect(withDelay delay: Double = 0.0) {
        centralQueue.sync {
            self.reconnectIfDisconnected(delay)
        }
    }
     
    public func connect(timeoutRetries: UInt = UInt.max, disconnectRetries: UInt = UInt.max, connectionTimeout: Double = Double.infinity, capacity: Int = Int.max) -> FutureStream<(peripheral: Peripheral, connectionEvent: ConnectionEvent)> {
        return centralQueue.sync {
            self.connectionPromise = StreamPromise<(peripheral: Peripheral, connectionEvent: ConnectionEvent)>(capacity: capacity)
            self.timeoutRetries = timeoutRetries
            self.disconnectRetries = disconnectRetries
            self.connectionTimeout = connectionTimeout
            Logger.debug("connect peripheral \(self.name)', \(self.identifier.uuidString)")
            self.reconnectIfDisconnected()
            return self.connectionPromise!.stream
        }
    }
    
    public func disconnect() {
        return centralQueue.sync {
            guard let central = self.centralManager else {
                return
            }
            self.forcedDisconnect = true
            self.pollRSSIPromise = nil
            self.readRSSIPromise = nil
            if self.state == .connected {
                Logger.debug("disconnecting name=\(self.name), uuid=\(self.identifier.uuidString)")
                central.cancelPeripheralConnection(self)
            } else {
                Logger.debug("already disconnected name=\(self.name), uuid=\(self.identifier.uuidString)")
                self.didDisconnectPeripheral(PeripheralError.disconnected)
            }
        }
    }
    
    public func terminate() {
        guard let central = self.centralManager else {
            return
        }
        central.discoveredPeripherals.removeValueForKey(self.cbPeripheral.identifier)
        if self.state == .connected {
            self.disconnect()
        }
    }

    fileprivate func reconnectIfDisconnected(_ delay: Double = 0.0) {
        guard let centralManager = self.centralManager , self.state == .disconnected  else {
            Logger.debug("peripheral not disconnected \(self.name), \(self.identifier.uuidString)")
            return
        }
        Logger.debug("reconnect peripheral name=\(self.name), uuid=\(self.identifier.uuidString)")
        let performConnection = {
            centralManager.connect(self)
            self.forcedDisconnect = false
            self.connectionSequence += 1
            self.currentError = .none
            self.timeoutConnection(self.connectionSequence)
        }
        if delay > 0.0 {
            centralManager.centralQueue.delay(delay) {
                performConnection()
            }
        } else {
            performConnection()
        }
    }

    // MARK: Discover Services

    public func discoverAllServices(_ timeout: Double = Double.infinity) -> Future<Peripheral> {
        Logger.debug("uuid=\(self.identifier.uuidString), name=\(self.name)")
        return self.discoverServices(nil, timeout: timeout)
    }

    public func discoverServices(_ services: [CBUUID]?, timeout: Double = Double.infinity) -> Future<Peripheral> {
        Logger.debug(" \(self.name)")
        return self.discoverIfConnected(services, timeout: timeout)
    }
    
    // MARK: CBPeripheralDelegate

    public func peripheralDidUpdateName(_:CBPeripheral) {
        Logger.debug()
    }
    
    public func peripheral(_: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        Logger.debug()
    }

    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        didReadRSSI(RSSI, error:error)
    }

    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let services = self.cbPeripheral.getServices() {
            didDiscoverServices(services, error: error)
        }
    }
    
    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        Logger.debug("peripheral name \(self.name)")
    }
    
    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.getCharacteristics() else {
            return
        }
        didDiscoverCharacteristicsForService(service, characteristics: characteristics, error: error)
    }

    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateNotificationStateForCharacteristic(characteristic, error: error)
    }

    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValueForCharacteristic(characteristic, error: error)
    }

    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        didWriteValueForCharacteristic(characteristic, error: error)
    }

    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        Logger.debug()
    }
    
    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        Logger.debug()
    }
    
    @nonobjc public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        Logger.debug()
    }

    // MARK: CBPeripheralDelegate Shims

    internal func didDiscoverCharacteristicsForService(_ service: CBServiceInjectable, characteristics: [CBCharacteristicInjectable], error: Error?) {
        Logger.debug("uuid=\(self.identifier.uuidString), name=\(self.name)")
        if let bcService = self.discoveredServices[service.UUID] {
            bcService.didDiscoverCharacteristics(characteristics, error: error)
            if error == nil {
                for cbCharacteristic in characteristics {
                    self.discoveredCharacteristics[cbCharacteristic.UUID] = bcService.discoveredCharacteristics[cbCharacteristic.UUID]
                }
            }
        }
    }
    
    internal func didDiscoverServices(_ discoveredServices: [CBServiceInjectable], error: Error?) {
        Logger.debug("uuid=\(self.identifier.uuidString), name=\(self.name)")
        self.clearAll()
        if let error = error {
            self.servicesDiscoveredPromise?.failure(error)
        } else {
            for service in discoveredServices {
                let serviceProfile = profileManager?.services[service.UUID]
                let bcService = Service(cbService: service, peripheral: self, profile: serviceProfile)
                self.discoveredServices[bcService.UUID] = bcService
                Logger.debug("uuid=\(bcService.UUID.uuidString), name=\(bcService.name)")
            }
            self.servicesDiscoveredPromise?.success(self)
        }
    }
    
    internal func didUpdateNotificationStateForCharacteristic(_ characteristic: CBCharacteristicInjectable, error: Error?) {
        Logger.debug()
        if let bcCharacteristic = self.discoveredCharacteristics[characteristic.UUID] {
            Logger.debug("uuid=\(bcCharacteristic.UUID.uuidString), name=\(bcCharacteristic.name)")
            bcCharacteristic.didUpdateNotificationState(error)
        }
    }
    
    internal func didUpdateValueForCharacteristic(_ characteristic: CBCharacteristicInjectable, error: Error?) {
        Logger.debug()
        if let bcCharacteristic = self.discoveredCharacteristics[characteristic.UUID] {
            Logger.debug("uuid=\(bcCharacteristic.UUID.uuidString), name=\(bcCharacteristic.name)")
            bcCharacteristic.didUpdate(error)
        }
    }
    
    internal func didWriteValueForCharacteristic(_ characteristic: CBCharacteristicInjectable, error: Error?) {
        Logger.debug()
        if let bcCharacteristic = self.discoveredCharacteristics[characteristic.UUID] {
            Logger.debug("uuid=\(bcCharacteristic.UUID.uuidString), name=\(bcCharacteristic.name)")
            bcCharacteristic.didWrite(error)
        }
    }

    internal func didReadRSSI(_ RSSI: NSNumber, error: Error?) {
        if let error = error {
            Logger.debug("RSSI read failed: \(error.localizedDescription)")
            if let completed = self.readRSSIPromise?.completed, !completed {
                self.readRSSIPromise?.failure(error)
            }
            self.pollRSSIPromise?.failure(error)
        } else {
            Logger.debug("RSSI = \(RSSI.stringValue), peripheral name = \(self.name), uuid=\(self.identifier.uuidString), state = \(self.state.rawValue)")
            self.RSSI = RSSI.intValue
            if let completed = self.readRSSIPromise?.completed, !completed {
                self.readRSSIPromise?.success(RSSI.intValue)
            }
            self.pollRSSIPromise?.success(RSSI.intValue)
        }
    }

    // MARK: CBCentralManagerDelegate Shims

    internal func didConnectPeripheral() {
        Logger.debug("uuid=\(self.identifier.uuidString), name=\(self.name)")
        self.connectedAt = Date()
        self._disconnectedAt = nil
        self.connectionPromise?.success((self, .connect))
    }

    internal func didDisconnectPeripheral(_ error: Swift.Error?) {
        self._disconnectedAt = Date()
        self._totalSecondsConnected += self._secondsConnected
        switch(self.currentError) {
        case .none:
            if let error = error {
                Logger.debug("disconnecting with errors uuid=\(self.identifier.uuidString), name=\(self.name), error=\(error.localizedDescription)")
                self.shouldFailOrGiveUp(error)
            } else if (self.forcedDisconnect) {
                Logger.debug("disconnect forced uuid=\(self.identifier.uuidString), name=\(self.name)")
                self.forcedDisconnect = false
                self.connectionPromise?.success((self, .forceDisconnect))
            } else  {
                Logger.debug("disconnecting with no errors uuid=\(self.identifier.uuidString), name=\(self.name)")
                self.shouldDisconnectOrGiveup()
            }
        case .timeout:
            Logger.debug("timeout uuid=\(self.identifier.uuidString), name=\(self.name)")
            self.shouldTimeoutOrGiveup()
        }
        for service in self.services {
            service.didDisconnectPeripheral(error)
        }
    }

    internal func didFailToConnectPeripheral(_ error: Swift.Error?) {
        self.didDisconnectPeripheral(error)
    }

    // MARK: CBPeripheral Delegation

    internal func setNotifyValue(_ state: Bool, forCharacteristic characteristic: Characteristic) {
        self.cbPeripheral.setNotifyValue(state, forCharacteristic:characteristic.cbCharacteristic)
    }
    
    internal func readValueForCharacteristic(_ characteristic: Characteristic) {
        self.cbPeripheral.readValueForCharacteristic(characteristic.cbCharacteristic)
    }
    
    internal func writeValue(_ value: Data, forCharacteristic characteristic: Characteristic, type: CBCharacteristicWriteType = .withResponse) {
            self.cbPeripheral.writeValue(value, forCharacteristic:characteristic.cbCharacteristic, type:type)
    }
    
    internal func discoverCharacteristics(_ characteristics: [CBUUID]?, forService service: Service) {
        self.cbPeripheral.discoverCharacteristics(characteristics, forService:service.cbService)
    }

    // MARK: Utilities

    fileprivate func shouldFailOrGiveUp(_ error: Swift.Error) {
        Logger.debug("name=\(self.name), uuid=\(self.identifier.uuidString), disconnectCount=\(self._disconnectionCount), disconnectRetries=\(self.disconnectRetries)")
            if self._disconnectionCount < disconnectRetries {
                self._disconnectionCount += 1
                self.connectionPromise?.failure(error)
            } else {
                self.connectionPromise?.success((self, ConnectionEvent.giveUp))
            }
    }

    fileprivate func shouldTimeoutOrGiveup() {
        Logger.debug("name=\(self.name), uuid=\(self.identifier.uuidString), timeoutCount=\(self._timeoutCount), timeoutRetries=\(self.timeoutRetries)")
        if self._timeoutCount < timeoutRetries {
            self.connectionPromise?.success((self, .timeout))
            self._timeoutCount += 1
        } else {
            self.connectionPromise?.success((self, .giveUp))
        }
    }

    fileprivate func shouldDisconnectOrGiveup() {
        Logger.debug("name=\(self.name), uuid=\(self.identifier.uuidString), disconnectCount=\(self._disconnectionCount), disconnectRetries=\(self.disconnectRetries)")
        if self._disconnectionCount < disconnectRetries {
            self._disconnectionCount += 1
            self.connectionPromise?.success((self, .disconnect))
        } else {
            self.connectionPromise?.success((self, .giveUp))
        }
    }

    fileprivate func discoverIfConnected(_ services: [CBUUID]?, timeout: Double = Double.infinity)  -> Future<Peripheral> {
        return centralQueue.sync {
            if let servicesDiscoveredPromise = self.servicesDiscoveredPromise, !servicesDiscoveredPromise.completed {
                return servicesDiscoveredPromise.future
            }
            self.servicesDiscoveredPromise = Promise<Peripheral>()
            if self.state == .connected {
                self.serviceDiscoverySequence += 1
                self.timeoutServiceDiscovery(self.serviceDiscoverySequence, timeout: timeout)
                self.cbPeripheral.discoverServices(services)
            } else {
                self.servicesDiscoveredPromise?.failure(PeripheralError.disconnected)
            }
            return self.servicesDiscoveredPromise!.future
        }
    }

    fileprivate func clearAll() {
        self.discoveredServices.removeAll()
        self.discoveredCharacteristics.removeAll()
    }

    fileprivate func timeoutConnection(_ sequence: Int) {
        guard let centralManager = self.centralManager , connectionTimeout < Double.infinity else {
            return
        }
        Logger.debug("name = \(self.name), uuid = \(self.identifier.uuidString), sequence = \(sequence), timeout = \(self.connectionTimeout)")
        centralQueue.delay(self.connectionTimeout) {
            if self.state != .connected && sequence == self.connectionSequence && !self.forcedDisconnect {
                Logger.debug("connection timing out name = \(self.name), UUID = \(self.identifier.uuidString), sequence=\(sequence), current connectionSequence=\(self.connectionSequence)")
                self.currentError = .timeout
                centralManager.cancelPeripheralConnection(self)
            } else {
                Logger.debug("connection timeout expired name = \(self.name), uuid = \(self.identifier.uuidString), sequence = \(sequence), current connectionSequence=\(self.connectionSequence), state=\(self.state.rawValue)")
            }
        }
    }

    fileprivate func timeoutServiceDiscovery(_ sequence: Int, timeout: Double) {
        guard let centralManager = self.centralManager, timeout < Double.infinity else {
            return
        }
        Logger.debug("name = \(self.name), uuid = \(self.identifier.uuidString), sequence = \(sequence), timeout = \(timeout)")
        centralQueue.delay(timeout) {
            if let servicesDiscoveredPromise = self.servicesDiscoveredPromise, sequence == self.serviceDiscoverySequence && !servicesDiscoveredPromise.completed {
                Logger.debug("service scan timing out name = \(self.name), UUID = \(self.identifier.uuidString), sequence=\(sequence), current sequence=\(self.serviceDiscoverySequence)")
                centralManager.cancelPeripheralConnection(self)
                servicesDiscoveredPromise.failure(PeripheralError.serviceDiscoveryTimeout)
            } else {
                Logger.debug("service scan timeout expired name = \(self.name), uuid = \(self.identifier.uuidString), sequence = \(sequence), current sequence = \(self.serviceDiscoverySequence)")
            }
        }
    }

    fileprivate func pollRSSI(_ period: Double, sequence: Int) {
        Logger.debug("name = \(self.name), uuid = \(self.identifier.uuidString), period = \(period), sequence = \(sequence), current sequence = \(self.RSSISequence)")
        guard self.pollRSSIPromise != nil && sequence == self.RSSISequence else {
            Logger.debug("exiting: name = \(self.name), uuid = \(self.identifier.uuidString), sequence = \(sequence), current sequence = \(self.RSSISequence)")
            return
        }
        centralQueue.delay(period) {
            Logger.debug("trigger: name = \(self.name), uuid = \(self.identifier.uuidString), sequence = \(sequence), current sequence = \(self.RSSISequence)")
            self.readRSSIIfConnected()
            self.pollRSSI(period, sequence: sequence)
        }
    }

    fileprivate func readRSSIIfConnected() {
        if self.state == .connected {
            self.cbPeripheral.readRSSI()
        } else {
            self.readRSSIPromise?.failure(PeripheralError.disconnected)
            self.pollRSSIPromise?.failure(PeripheralError.disconnected)
        }
    }

}
