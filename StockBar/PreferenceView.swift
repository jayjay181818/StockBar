//
//  PreferenceView.swift
//  StockBar
//
//  Created by Hongliang Fan on 2020-08-02.

import SwiftUI

struct PreferenceRow : View {
    @ObservedObject var realTimeTrade : RealTimeTrade
    var body: some View {
        HStack {
            Spacer()
            TextField( "symbol", text: self.$realTimeTrade.trade.name )
            Spacer()
            TextField( "Units", text: self.$realTimeTrade.trade.position.unitSizeString )
            Spacer()
            TextField( "average position cost", text: self.$realTimeTrade.trade.position.positionAvgCostString )
            Spacer()
        }
    }
}

struct PreferenceView: View {
    @ObservedObject var userdata : DataModel
    
    var body: some View {
        VStack {
            HStack {
                Toggle("Color Coding", isOn: $userdata.showColorCoding)
                    .padding(.bottom, 10)
                Spacer()
            }
            
            HStack {
                Text("Preferred Currency:")
                Picker("", selection: $userdata.preferredCurrency) {
                    ForEach(DataModel.supportedCurrencies, id: \.self) { currency in
                        Text(currency).tag(currency)
                    }
                }
                .frame(width: 100)
                Spacer()
            }
            .padding(.bottom, 10)
            
            // Display total net gains
            HStack {
                Text("Total Net Gains:")
                let gains = userdata.calculateNetGains()
                let formattedAmount = String(format: "%+.2f", gains.amount)
                Text("\(formattedAmount) \(gains.currency)")
                    .foregroundColor(gains.amount >= 0 ? .green : .red)
                Spacer()
            }
            .padding(.bottom, 10)
            // Force view to update when trades change
            .id(userdata.realTimeTrades.map { $0.realTimeInfo.currentPrice }.reduce(0, +))
            HStack {
                Spacer()
                Text("Symbol")
                Spacer()
                Text("Units")
                Spacer()
                Text("Avg position cost")
                Button(action: {
                    let emptyTrade = emptyRealTimeTrade()
                    self.userdata.realTimeTrades.insert(emptyTrade, at: 0)
                    }
                ){
                    Text("+")
                }
            }
            ForEach(userdata.realTimeTrades) { item in
                HStack {
                    Button(action: {
                        if let index = self.userdata.realTimeTrades.map({$0.id}).firstIndex(of: item.id) {
                            self.userdata.realTimeTrades.remove(at: index)
                        }
                    }){
                        Text("-")
                    }
                    PreferenceRow(realTimeTrade: item)
                    Button(action: {
                        let emptyTrade = emptyRealTimeTrade()
                        if let index = self.userdata.realTimeTrades.map({$0.id}).firstIndex(of: item.id) {
                            self.userdata.realTimeTrades.insert(emptyTrade, at: index+1)
                        }
                    }){
                        Text("+")
                    }
                }
                
            }
        }.padding()
    }
}

struct PreferenceView_Previews: PreviewProvider {
    static var previews: some View {
        PreferenceView(userdata: DataModel())
    }
}
